defmodule ElixirChat.Workers.PruneOutboxEvents do
  @moduledoc """
  Daily cleanup of published `outbox_events` older than the configured
  retention window (`:elixir_chat, ElixirChat.Retention, :outbox_events_days`)
  — see `ElixirChat.Chat.Outbox.delete_published_before/2` for what counts as
  eligible. Scheduled by Oban's `:cron` feature (`config/config.exs`).
  """

  use Oban.Worker, queue: :cleanup, unique: [period: 60]

  alias ElixirChat.Chat.Outbox
  alias ElixirChat.Workers.BatchDelete

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
    BatchDelete.run(fn -> Outbox.delete_published_before(cutoff) end)
    :ok
  end

  defp retention_days do
    Application.fetch_env!(:elixir_chat, ElixirChat.Retention)[:outbox_events_days]
  end
end
