defmodule ElixirChat.Repo.Migrations.AddSearchIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_active_display_name_trgm_index
    ON users USING gin (display_name gin_trgm_ops)
    WHERE disabled_at IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS users_active_login_trgm_index
    ON users USING gin ((login::text) gin_trgm_ops)
    WHERE disabled_at IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_body_simple_fts_index
    ON messages USING gin (to_tsvector('simple', body))
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS direct_conversations_first_activity_cursor_index
    ON direct_conversations (first_user_id, last_activity_at DESC, id DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS direct_conversations_second_activity_cursor_index
    ON direct_conversations (second_user_id, last_activity_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS direct_conversations_second_activity_cursor_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS direct_conversations_first_activity_cursor_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS messages_body_simple_fts_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_active_login_trgm_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS users_active_display_name_trgm_index")
  end
end
