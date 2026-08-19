defmodule ElixirChat.Workers.PruneNotifications do
  @moduledoc """
  Daily cleanup of read `notifications` older than the configured retention
  window (`:elixir_chat, ElixirChat.Retention, :notifications_read_days`) —
  see `ElixirChat.Notifications.delete_read_notifications_before/2`. Unread
  notifications are never matched, regardless of age. Scheduled by Oban's
  `:cron` feature (`config/config.exs`).
  """

  use Oban.Worker, queue: :cleanup, unique: [period: 60]

  alias ElixirChat.Notifications
  alias ElixirChat.Workers.BatchDelete

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
    BatchDelete.run(fn -> Notifications.delete_read_notifications_before(cutoff) end)
    :ok
  end

  defp retention_days do
    Application.fetch_env!(:elixir_chat, ElixirChat.Retention)[:notifications_read_days]
  end
end
