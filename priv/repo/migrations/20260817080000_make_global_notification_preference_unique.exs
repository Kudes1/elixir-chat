defmodule ElixirChat.Repo.Migrations.MakeGlobalNotificationPreferenceUnique do
  use Ecto.Migration

  @index_name :notification_preferences_user_id_channel_id_index

  def up do
    drop_if_exists index(:notification_preferences, [:user_id, :channel_id], name: @index_name)

    create unique_index(:notification_preferences, [:user_id, :channel_id],
             name: @index_name,
             nulls_distinct: false
           )
  end

  def down do
    drop_if_exists index(:notification_preferences, [:user_id, :channel_id], name: @index_name)
    create unique_index(:notification_preferences, [:user_id, :channel_id], name: @index_name)
  end
end
