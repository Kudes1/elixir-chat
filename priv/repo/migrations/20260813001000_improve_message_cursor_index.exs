defmodule ElixirChat.Repo.Migrations.ImproveMessageCursorIndex do
  use Ecto.Migration

  def change do
    drop_if_exists index(:messages, [:channel_id, :inserted_at])
    create index(:messages, [:channel_id, :inserted_at, :id])
  end
end
