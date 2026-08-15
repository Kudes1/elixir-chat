defmodule ElixirChat.Repo.Migrations.DropMessageSearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS messages_body_simple_fts_index")
  end

  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_body_simple_fts_index
    ON messages USING gin (to_tsvector('simple', body))
    """)
  end
end
