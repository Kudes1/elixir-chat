defmodule ElixirChat.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  # `version: 1` ensures a full rollback regardless of which version was
  # migrated up to.
  def down do
    Oban.Migration.down(version: 1)
  end
end
