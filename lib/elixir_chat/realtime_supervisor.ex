defmodule ElixirChat.RealtimeSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {ElixirChat.RealtimeProcessManager,
         name: ElixirChat.PubSubManager,
         child: Phoenix.PubSub,
         child_opts: [name: ElixirChat.PubSub]},
        {ElixirChat.RealtimeProcessManager,
         name: ElixirChat.PresenceManager, child: ElixirChatWeb.Presence},
        ElixirChat.RealtimeConsumersSupervisor
      ],
      strategy: :rest_for_one
    )
  end
end
