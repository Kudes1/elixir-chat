defmodule ElixirChat.Repo.Migrations.AddAccountsAndAuth do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
    execute "CREATE TYPE user_role AS ENUM ('user', 'admin')"

    execute "CREATE TYPE invitation_kind AS ENUM ('user_registration', 'admin_bootstrap', 'password_reset')"

    create table(:users) do
      add :login, :citext, null: false
      add :display_name, :string, null: false
      add :hashed_password, :string, null: false
      add :role, :user_role, null: false, default: "user"
      add :disabled_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:login])
    create unique_index(:users, [:role], where: "role = 'admin'", name: :users_single_admin_index)

    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :authenticated_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_tokens, [:context, :token])
    create index(:user_tokens, [:user_id])

    create table(:invitations) do
      add :kind, :invitation_kind, null: false
      add :token_hash, :binary, null: false
      add :login, :citext
      add :display_name, :string
      add :user_id, references(:users, on_delete: :restrict)
      add :created_by_id, references(:users, on_delete: :restrict)
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:invitations, [:token_hash])

    create index(:invitations, [:login],
             where: "kind = 'user_registration' AND used_at IS NULL AND revoked_at IS NULL"
           )

    create table(:audit_events) do
      add :actor_id, references(:users, on_delete: :restrict)
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :bigint
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    execute """
    CREATE FUNCTION prevent_audit_event_changes() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'audit events are immutable'; END;
    $$ LANGUAGE plpgsql
    """

    execute "CREATE TRIGGER audit_events_immutable BEFORE UPDATE OR DELETE ON audit_events FOR EACH ROW EXECUTE FUNCTION prevent_audit_event_changes()"

    alter table(:messages) do
      add :user_id, references(:users, on_delete: :restrict)
    end

    create index(:messages, [:user_id])
  end

  def down do
    alter table(:messages), do: remove(:user_id)
    execute "DROP TRIGGER audit_events_immutable ON audit_events"
    execute "DROP FUNCTION prevent_audit_event_changes()"
    drop table(:audit_events)
    drop table(:invitations)
    drop table(:user_tokens)
    drop table(:users)
    execute "DROP TYPE invitation_kind"
    execute "DROP TYPE user_role"
    execute "DROP EXTENSION IF EXISTS citext"
  end
end
