defmodule ElixirChat.Repo.Migrations.AddConversationReads do
  use Ecto.Migration

  def up do
    create table(:conversation_reads) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :last_read_at, :utc_datetime
      # Intentionally not a foreign key: deleting the boundary message must not
      # move the durable cursor backwards.
      add :last_read_message_id, :bigint

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_reads, [:user_id, :channel_id])
    create index(:conversation_reads, [:channel_id, :user_id])

    execute """
    INSERT INTO conversation_reads
      (user_id, channel_id, last_read_at, last_read_message_id, inserted_at, updated_at)
    SELECT access.user_id, access.channel_id, latest.inserted_at, latest.id, NOW(), NOW()
    FROM (
      SELECT memberships.user_id, memberships.channel_id
      FROM channel_memberships AS memberships
      JOIN channels ON channels.id = memberships.channel_id
      WHERE channels.purpose = 'group'

      UNION

      SELECT users.id, channels.id
      FROM channels
      CROSS JOIN users
      WHERE channels.purpose = 'group'
        AND channels.kind = 'public'
        AND channels.archived_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM channel_memberships
          WHERE channel_memberships.channel_id = channels.id
        )

      UNION

      SELECT direct.first_user_id, direct.channel_id FROM direct_conversations AS direct
      UNION
      SELECT direct.second_user_id, direct.channel_id FROM direct_conversations AS direct
    ) AS access
    LEFT JOIN LATERAL (
      SELECT messages.id, messages.inserted_at
      FROM messages
      WHERE messages.channel_id = access.channel_id
      ORDER BY messages.inserted_at DESC, messages.id DESC
      LIMIT 1
    ) AS latest ON TRUE
    ON CONFLICT (user_id, channel_id) DO NOTHING
    """
  end

  def down do
    drop table(:conversation_reads)
  end
end
