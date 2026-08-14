defmodule ElixirChat.Repo.Migrations.AddDirectConversations do
  use Ecto.Migration

  def change do
    create table(:direct_conversations) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :first_user_id, references(:users, on_delete: :restrict), null: false
      add :second_user_id, references(:users, on_delete: :restrict), null: false
      add :last_activity_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:direct_conversations, [:channel_id])
    create unique_index(:direct_conversations, [:first_user_id, :second_user_id])
    create index(:direct_conversations, [:first_user_id, :last_activity_at])
    create index(:direct_conversations, [:second_user_id, :last_activity_at])

    create constraint(:direct_conversations, :direct_conversations_distinct_ordered_users,
             check: "first_user_id < second_user_id"
           )
  end
end
