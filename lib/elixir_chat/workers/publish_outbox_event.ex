defmodule ElixirChat.Workers.PublishOutboxEvent do
  @moduledoc """
  Publishes one durable `ElixirChat.Chat.OutboxEvent` to PubSub/push —
  replaces the old poll-based `ElixirChat.OutboxDispatcher`, which claimed
  batches with a manual `FOR UPDATE SKIP LOCKED` query.

  Durability is a hard requirement here (this is the record of a committed
  message), so this worker never truly gives up: `max_attempts` is
  effectively unbounded and `backoff/1` caps the delay, matching the old
  dispatcher's "retry forever with capped exponential backoff" behavior. Past
  10 attempts it also logs/telemetries once, purely for operator visibility
  — it keeps retrying regardless.

  Ordering per `partition_key` (one channel/direct conversation) must still
  hold even though the `:outbox` queue runs several jobs concurrently across
  *different* partitions: before publishing, a job checks whether an earlier
  (lower `id`), same-partition event is still unpublished and, if so,
  `{:snooze, _}`s itself — which reschedules the job without spending one of
  its attempts — rather than publish out of order.
  """

  use Oban.Worker, queue: :outbox, max_attempts: 1_000_000

  import Ecto.Query

  require Logger

  alias ElixirChat.Chat.OutboxEvent
  alias ElixirChat.OutboxPublisher
  alias ElixirChat.Repo

  @snooze_seconds 1
  @warn_after_attempts 10

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(round(:math.pow(2, min(attempt - 1, 6))), 60)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}, attempt: attempt}) do
    case Repo.get(OutboxEvent, id) do
      nil -> :ok
      %OutboxEvent{published_at: %DateTime{}} -> :ok
      %OutboxEvent{} = event -> publish_in_order(event, attempt)
    end
  end

  defp publish_in_order(event, attempt) do
    if earlier_unpublished?(event) do
      {:snooze, @snooze_seconds}
    else
      :ok = invoke_publisher(publisher(), event)

      event
      |> Ecto.Changeset.change(published_at: DateTime.utc_now())
      |> Repo.update!()

      :ok
    end
  rescue
    exception ->
      maybe_warn(event, attempt, exception)
      {:error, exception}
  catch
    kind, reason ->
      maybe_warn(event, attempt, {kind, reason})
      {:error, {kind, reason}}
  end

  # Overridable in tests (`Application.put_env(:elixir_chat, __MODULE__, publisher: ...)`),
  # same pattern as `ElixirChat.Notifications.adapter/0` — lets ordering/retry
  # tests use a trivial fake instead of a fully realistic encoded message.
  defp publisher,
    do: Application.get_env(:elixir_chat, __MODULE__, [])[:publisher] || OutboxPublisher

  defp invoke_publisher(publisher, event) when is_function(publisher, 1), do: publisher.(event)
  defp invoke_publisher(publisher, event), do: publisher.publish(event)

  defp earlier_unpublished?(%OutboxEvent{id: id, partition_key: partition_key}) do
    Repo.exists?(
      from earlier in OutboxEvent,
        where:
          earlier.partition_key == ^partition_key and is_nil(earlier.published_at) and
            earlier.id < ^id
    )
  end

  defp maybe_warn(event, attempt, reason) when attempt >= @warn_after_attempts do
    Logger.warning("outbox event #{event.event_id} failed #{attempt} times: #{inspect(reason)}")

    :telemetry.execute(
      [:elixir_chat, :outbox, :retry_exhausted],
      %{attempt_count: attempt},
      %{event_id: event.event_id, partition_key: event.partition_key, error: inspect(reason)}
    )
  end

  defp maybe_warn(_event, _attempt, _reason), do: :ok
end
