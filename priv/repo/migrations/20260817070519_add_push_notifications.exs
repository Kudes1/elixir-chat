defmodule ElixirChat.Repo.Migrations.AddPushNotifications do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:user_id, :endpoint])
    create index(:push_subscriptions, [:user_id])

    create table(:notification_preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # nil = global preference (applies to direct chats and channels not
      # otherwise configured); otherwise the conversation's channel id.
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :muted, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_preferences, [:user_id, :channel_id])
    create index(:notification_preferences, [:user_id])
  end
end
