defmodule ElixirChat.OutboxDispatcher do
  @moduledoc "Durably publishes committed message events with at-least-once semantics."

  use GenServer
  require Logger
  import Ecto.Query

  alias ElixirChat.Chat.OutboxEvent
  alias ElixirChat.Repo

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def dispatch_now(server \\ __MODULE__), do: GenServer.call(server, :dispatch_now, :infinity)

  def wake_up(server \\ __MODULE__) do
    if Application.get_env(:elixir_chat, __MODULE__, [])[:synchronous_wake_up] do
      GenServer.call(server, :wake_up, :infinity)
    else
      GenServer.cast(server, :wake_up)
    end
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:elixir_chat, __MODULE__, [])

    state = %{
      interval: Keyword.get(opts, :interval, config[:interval] || 1_000),
      batch_size: Keyword.get(opts, :batch_size, config[:batch_size] || 50),
      retention: Keyword.get(opts, :retention, config[:retention] || :timer.hours(24 * 7)),
      publisher: Keyword.get(opts, :publisher, config[:publisher] || ElixirChat.OutboxPublisher)
    }

    schedule_poll(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:dispatch_now, _from, state) do
    {:reply, dispatch(state), state}
  end

  @impl true
  def handle_call(:wake_up, _from, state) do
    {:reply, dispatch(state), state}
  end

  @impl true
  def handle_cast(:wake_up, state) do
    dispatch(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    dispatch(state)
    schedule_poll(state.interval)
    {:noreply, state}
  end

  defp dispatch(state) do
    result =
      Repo.transaction(fn ->
        events = claim_events(state.batch_size)
        Enum.each(events, &publish(&1, state.publisher))
        length(events)
      end)

    delete_expired(state.retention)

    case result do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      Logger.error("outbox dispatch failed: #{Exception.message(exception)}")
      {:error, exception}
  end

  defp claim_events(limit) do
    now = DateTime.utc_now()

    OutboxEvent
    |> where([event], is_nil(event.published_at) and event.available_at <= ^now)
    |> where(
      [event],
      fragment(
        "NOT EXISTS (SELECT 1 FROM outbox_events earlier WHERE earlier.partition_key = ? AND earlier.published_at IS NULL AND earlier.id < ?)",
        event.partition_key,
        event.id
      )
    )
    |> order_by([event], asc: event.id)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp publish(event, publisher) do
    case invoke_publisher(publisher, event) do
      :ok ->
        event
        |> Ecto.Changeset.change(published_at: DateTime.utc_now(), last_error: nil)
        |> Repo.update!()

      {:error, reason} ->
        record_failure(event, reason)

      other ->
        record_failure(event, {:unexpected_publisher_result, other})
    end
  rescue
    exception -> record_failure(event, exception)
  catch
    kind, reason -> record_failure(event, {kind, reason})
  end

  defp invoke_publisher(publisher, event) when is_function(publisher, 1), do: publisher.(event)
  defp invoke_publisher(publisher, event), do: publisher.publish(event)

  defp record_failure(event, reason) do
    attempts = event.attempt_count + 1
    delay_seconds = min(round(:math.pow(2, min(attempts - 1, 6))), 60)
    error = Exception.format_banner(:error, reason, []) |> String.slice(0, 4_000)

    event
    |> Ecto.Changeset.change(
      attempt_count: attempts,
      available_at: DateTime.add(DateTime.utc_now(), delay_seconds, :second),
      last_error: error
    )
    |> Repo.update!()

    if attempts >= 10 do
      Logger.warning("outbox event #{event.event_id} failed #{attempts} times: #{error}")

      :telemetry.execute(
        [:elixir_chat, :outbox, :retry_exhausted],
        %{attempt_count: attempts},
        %{event_id: event.event_id, partition_key: event.partition_key, error: error}
      )
    end

    :error
  end

  defp delete_expired(retention) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention, :millisecond)
    Repo.delete_all(from event in OutboxEvent, where: event.published_at < ^cutoff)
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
