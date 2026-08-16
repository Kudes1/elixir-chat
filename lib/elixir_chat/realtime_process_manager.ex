defmodule ElixirChat.RealtimeProcessManager do
  @moduledoc false

  use GenServer

  @shutdown_delay 25

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    module = Keyword.fetch!(opts, :child)
    child_opts = Keyword.get(opts, :child_opts, [])

    %{start: {start_module, function, args}} = Supervisor.child_spec({module, child_opts}, [])

    case apply(start_module, function, args) do
      {:ok, child} -> {:ok, %{child: child, reason: nil}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, child, reason}, %{child: child} = state) do
    Process.send_after(self(), :dependency_stopped, @shutdown_delay)
    {:noreply, %{state | child: nil, reason: reason}}
  end

  def handle_info(:dependency_stopped, state),
    do: {:stop, {:dependency_stopped, state.reason}, state}
end
