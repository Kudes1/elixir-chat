defmodule ElixirChat.Workers.PrunePushDeliveries do
  @moduledoc """
  Daily safety-net cleanup of `push_deliveries` rows older than the
  configured retention window
  (`:elixir_chat, ElixirChat.Retention, :push_deliveries_days`) — see
  `ElixirChat.Notifications.delete_stale_deliveries_before/2`. Scheduled by
  Oban's `:cron` feature (`config/config.exs`).
  """

  use Oban.Worker, queue: :cleanup, unique: [period: 60]

  alias ElixirChat.Notifications
  alias ElixirChat.Workers.BatchDelete

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
    BatchDelete.run(fn -> Notifications.delete_stale_deliveries_before(cutoff) end)
    :ok
  end

  defp retention_days do
    Application.fetch_env!(:elixir_chat, ElixirChat.Retention)[:push_deliveries_days]
  end
end
