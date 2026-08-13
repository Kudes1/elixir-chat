defmodule ElixirChat.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  def change do
    create table(:channels) do
      add :name, :string, null: false
      add :description, :string
      add :kind, :string, null: false, default: "public"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channels, [:name])

    create table(:messages) do
      add :author_name, :string, null: false
      add :body, :text, null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:channel_id, :inserted_at])
  end
end
