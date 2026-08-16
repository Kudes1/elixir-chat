defmodule ElixirChat.Repo.Migrations.AddMessageOutbox do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :client_message_id, :uuid
    end

    execute "UPDATE messages SET client_message_id = gen_random_uuid() WHERE client_message_id IS NULL"
    execute "ALTER TABLE messages ALTER COLUMN client_message_id SET NOT NULL"
    create unique_index(:messages, [:user_id, :client_message_id])

    create table(:outbox_events) do
      add :event_id, :uuid, null: false
      add :event_type, :string, null: false
      add :partition_key, :string, null: false
      add :payload, :map, null: false
      add :attempt_count, :integer, null: false, default: 0
      add :available_at, :utc_datetime_usec, null: false
      add :published_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:outbox_events, [:event_id])
    create index(:outbox_events, [:published_at, :available_at, :id])
    create index(:outbox_events, [:partition_key, :id])
  end

  def down do
    drop table(:outbox_events)
    drop index(:messages, [:user_id, :client_message_id])

    alter table(:messages) do
      remove :client_message_id
    end
  end
end
