defmodule ElixirChat.Repo.Migrations.DropManualRetryColumns do
  @moduledoc """
  Oban's own job table now owns attempt counting, backoff scheduling, and
  discard state for both outbox publication and push delivery (see
  `ElixirChat.Workers.PublishOutboxEvent` / `ElixirChat.Workers.DeliverPushNotification`,
  replacing the old poll-based `ElixirChat.OutboxDispatcher` /
  `ElixirChat.NotificationSender`) — these columns duplicated that state
  alongside `oban_jobs` and are no longer written to.
  """

  use Ecto.Migration

  def change do
    alter table(:outbox_events) do
      remove :attempt_count, :integer, default: 0
      remove :available_at, :utc_datetime_usec
      remove :last_error, :string
    end

    alter table(:push_deliveries) do
      remove :attempt_count, :integer, default: 0
      remove :available_at, :utc_datetime
      remove :last_error, :string
    end
  end
end
