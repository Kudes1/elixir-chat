defmodule ElixirChat.EndpointManager do
  @moduledoc false

  use GenServer

  @max_restarts 3
  @max_seconds 5
  @retry_delay 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case ElixirChatWeb.Endpoint.start_link([]) do
      {:ok, endpoint} -> {:ok, %{endpoint: endpoint, restarts: []}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, endpoint, _reason}, %{endpoint: endpoint} = state) do
    Process.send_after(self(), :restart_endpoint, @retry_delay)
    {:noreply, %{state | endpoint: nil}}
  end

  def handle_info(:restart_endpoint, state) do
    restarts = recent_restarts(state.restarts)

    if length(restarts) >= @max_restarts do
      {:stop, :shutdown, state}
    else
      case ElixirChatWeb.Endpoint.start_link([]) do
        {:ok, endpoint} ->
          {:noreply, %{state | endpoint: endpoint, restarts: [now() | restarts]}}

        {:error, _reason} ->
          Process.send_after(self(), :restart_endpoint, @retry_delay)
          {:noreply, %{state | restarts: [now() | restarts]}}
      end
    end
  end

  defp recent_restarts(restarts) do
    cutoff = now() - System.convert_time_unit(@max_seconds, :second, :native)
    Enum.filter(restarts, &(&1 >= cutoff))
  end

  defp now, do: System.monotonic_time()
end
