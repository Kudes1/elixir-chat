defmodule ElixirChat.RealtimeConsumersSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([ElixirChat.OnlineUsers, ElixirChat.EndpointManager], strategy: :one_for_one)
  end
end
