defmodule ElixirChat.Repo.Migrations.AddRetentionCleanupIndexes do
  @moduledoc """
  Indexes for the retention/cleanup workers (`ElixirChat.Workers.Prune*`).

  `outbox_events` lost its only `published_at` index for free when
  `20260819000100_drop_manual_retry_columns.exs` dropped the `available_at`
  column that index was compound on (Postgres drops indexes that reference a
  removed column) — this restores one, scoped to published rows since that's
  all cleanup ever scans. `push_deliveries`/`notifications` never had an
  `inserted_at` index; cleanup is the first thing to scan by age.
  """

  use Ecto.Migration

  def change do
    create index(:outbox_events, [:published_at], where: "published_at IS NOT NULL")
    create index(:push_deliveries, [:inserted_at])
    create index(:notifications, [:inserted_at])
  end
end
