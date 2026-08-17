defmodule ElixirChat.NotificationSender do
  @moduledoc "Polls durable Web Push jobs and delivers them with bounded concurrency."

  use GenServer

  require Logger

  alias ElixirChat.Notifications

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def wake_up(server \\ __MODULE__), do: GenServer.cast(server, :wake_up)
  def dispatch_now(server \\ __MODULE__), do: GenServer.call(server, :dispatch_now, :infinity)

  @impl true
  def init(opts) do
    config = Application.get_env(:elixir_chat, __MODULE__, [])

    state = %{
      interval: Keyword.get(opts, :interval, config[:interval] || 1_000),
      batch_size: Keyword.get(opts, :batch_size, config[:batch_size] || 50),
      max_concurrency: Keyword.get(opts, :max_concurrency, config[:max_concurrency] || 8),
      task_timeout: Keyword.get(opts, :task_timeout, config[:task_timeout] || 15_000)
    }

    schedule_poll(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_cast(:wake_up, state) do
    dispatch(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:dispatch_now, _from, state) do
    {:reply, dispatch(state), state}
  end

  @impl true
  def handle_info(:poll, state) do
    dispatch(state)
    schedule_poll(state.interval)
    {:noreply, state}
  end

  defp dispatch(state) do
    delivery_ids =
      if Notifications.enabled?(), do: Notifications.due_delivery_ids(state.batch_size), else: []

    results =
      Task.async_stream(delivery_ids, &Notifications.deliver_delivery/1,
        max_concurrency: state.max_concurrency,
        ordered: true,
        timeout: state.task_timeout,
        on_timeout: :kill_task
      )

    delivery_ids
    |> Enum.zip(results)
    |> Enum.each(fn
      {_delivery_id, {:ok, _result}} ->
        :ok

      {delivery_id, {:exit, reason}} ->
        Logger.warning("push notification task exited: #{inspect(reason)}")
        Notifications.fail_delivery(delivery_id, {:task_exit, reason})
    end)

    {:ok, length(delivery_ids)}
  rescue
    error ->
      Logger.warning(
        "push notification dispatch raised #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      {:error, error}
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
end
