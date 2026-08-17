defmodule ElixirChat.NotificationSender do
  @moduledoc "Serializes asynchronous Web Push deliveries for created messages."

  use GenServer

  require Logger

  alias ElixirChat.Notifications

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:send, :channel, message}, state) do
    if Notifications.enabled?() do
      Logger.info("push notification job started",
        kind: :channel,
        message_id: message.id,
        channel_id: message.channel_id
      )

      safely_process(fn -> Notifications.process(:channel, message) end)
    end

    {:noreply, state}
  end

  def handle_cast({:send, :direct, message, direct}, state) do
    if Notifications.enabled?() do
      Logger.info("push notification job started",
        kind: :direct,
        message_id: message.id,
        channel_id: message.channel_id
      )

      safely_process(fn -> Notifications.process(:direct, message, direct) end)
    end

    {:noreply, state}
  end

  defp safely_process(fun) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "push notification job raised #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "push notification job stopped with #{Exception.format(kind, reason, __STACKTRACE__)}"
      )
  end
end
