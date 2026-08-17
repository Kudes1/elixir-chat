defmodule ElixirChat.Repo.Migrations.SecureAndQueuePushNotifications do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM push_subscriptions AS older
    USING push_subscriptions AS newer
    WHERE older.endpoint = newer.endpoint
      AND (older.updated_at, older.id) < (newer.updated_at, newer.id)
    """)

    drop_if_exists unique_index(:push_subscriptions, [:user_id, :endpoint])
    create unique_index(:push_subscriptions, [:endpoint])

    create table(:push_deliveries) do
      add :subscription_id, references(:push_subscriptions, on_delete: :delete_all), null: false
      add :recipient_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :payload, :map, null: false
      add :attempt_count, :integer, null: false, default: 0
      add :available_at, :utc_datetime, null: false
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_deliveries, [:subscription_id, :message_id])
    create index(:push_deliveries, [:available_at])
    create index(:push_deliveries, [:recipient_id])
  end

  def down do
    drop table(:push_deliveries)
    drop_if_exists unique_index(:push_subscriptions, [:endpoint])
    create unique_index(:push_subscriptions, [:user_id, :endpoint])
  end
end
