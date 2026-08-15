defmodule ElixirChat.RepoDiagnostics do
  @moduledoc "Logs slow database execution and connection-pool queue waits."

  require Logger

  @event [:elixir_chat, :repo, :query]

  def attach do
    case :telemetry.attach(
           "elixir-chat-repo-diagnostics",
           @event,
           &__MODULE__.handle_event/4,
           thresholds()
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def handle_event(_event, measurements, metadata, thresholds) do
    query_ms = to_ms(measurements[:query_time] || 0)
    queue_ms = to_ms(measurements[:queue_time] || 0)

    if query_ms >= thresholds.slow_query_ms do
      Logger.warning("slow database query",
        query_ms: Float.round(query_ms, 1),
        source: metadata[:source]
      )
    end

    if queue_ms >= thresholds.queue_warn_ms do
      Logger.warning("database pool queue wait",
        queue_ms: Float.round(queue_ms, 1),
        source: metadata[:source]
      )
    end
  end

  defp thresholds do
    Application.get_env(:elixir_chat, __MODULE__, [])
    |> Map.new()
  end

  defp to_ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1_000
end
