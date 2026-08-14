defmodule ElixirChat.Repo.Migrations.AddGroupChannelMemberships do
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :purpose, :string, null: false, default: "group"
      add :owner_id, references(:users, on_delete: :restrict)
      add :is_general, :boolean, null: false, default: false
      add :archived_at, :utc_datetime
    end

    create index(:channels, [:owner_id])
    create index(:channels, [:purpose, :archived_at])

    create table(:channel_memberships) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_memberships, [:channel_id, :user_id])
    create index(:channel_memberships, [:user_id, :channel_id])

    execute """
    UPDATE channels
    SET purpose = 'direct'
    WHERE id IN (SELECT channel_id FROM direct_conversations)
    """

    execute "UPDATE channels SET is_general = TRUE WHERE name = 'general' AND purpose = 'group'"

    execute """
    INSERT INTO channel_memberships (channel_id, user_id, inserted_at, updated_at)
    SELECT channels.id, users.id, NOW(), NOW()
    FROM channels CROSS JOIN users
    WHERE channels.purpose = 'group' AND channels.kind = 'public'
    ON CONFLICT (channel_id, user_id) DO NOTHING
    """

    execute """
    UPDATE channels
    SET owner_id = (SELECT id FROM users WHERE role = 'admin' LIMIT 1)
    WHERE purpose = 'group' AND owner_id IS NULL
      AND EXISTS (SELECT 1 FROM users WHERE role = 'admin')
    """

    execute """
    INSERT INTO channel_memberships (channel_id, user_id, inserted_at, updated_at)
    SELECT channels.id, channels.owner_id, NOW(), NOW()
    FROM channels
    WHERE channels.purpose = 'group' AND channels.owner_id IS NOT NULL
    ON CONFLICT (channel_id, user_id) DO NOTHING
    """
  end

  def down do
    drop table(:channel_memberships)

    alter table(:channels) do
      remove :archived_at
      remove :is_general
      remove :owner_id
      remove :purpose
    end
  end
end
