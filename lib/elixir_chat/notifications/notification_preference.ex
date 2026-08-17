defmodule ElixirChat.Notifications.NotificationPreference do
  @moduledoc "Per-conversation (or global) notification muting preference."

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.Channel

  schema "notification_preferences" do
    field :muted, :boolean, default: false
    belongs_to :user, User
    # nil => global preference; otherwise the conversation's channel id.
    belongs_to :channel, Channel

    timestamps(type: :utc_datetime)
  end

  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:user_id, :channel_id, :muted])
    |> validate_required([:user_id, :muted])
    |> unique_constraint([:user_id, :channel_id],
      name: :notification_preferences_user_id_channel_id_index
    )
  end
end
