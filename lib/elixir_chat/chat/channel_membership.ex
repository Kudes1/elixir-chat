defmodule ElixirChat.Chat.ChannelMembership do
  @moduledoc "Membership of an active user in a group channel."

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.Channel

  schema "channel_memberships" do
    belongs_to :channel, Channel
    belongs_to :user, User
    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:channel_id, :user_id])
    |> validate_required([:channel_id, :user_id])
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:channel_id, :user_id])
  end
end
