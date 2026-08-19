defmodule ElixirChat.Repo.Migrations.AddNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :type, :string, null: false
      add :recipient_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notifications, [:message_id, :recipient_id, :type])
    create index(:notifications, [:recipient_id])
  end
end
