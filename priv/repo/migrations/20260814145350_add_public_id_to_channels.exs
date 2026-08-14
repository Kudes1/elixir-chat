defmodule ElixirChat.Repo.Migrations.AddPublicIdToChannels do
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :public_id, :uuid
    end

    flush()

    execute("UPDATE channels SET public_id = gen_random_uuid() WHERE public_id IS NULL")
    flush()

    alter table(:channels) do
      modify :public_id, :uuid, null: false
    end

    create unique_index(:channels, [:public_id])
  end

  def down do
    drop_if_exists unique_index(:channels, [:public_id])

    alter table(:channels) do
      remove :public_id
    end
  end
end
