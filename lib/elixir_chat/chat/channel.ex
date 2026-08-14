defmodule ElixirChat.Chat.Channel do
  @moduledoc "A group channel or the backing conversation for a direct message."

  use Ecto.Schema
  import Ecto.Changeset

  schema "channels" do
    field :name, :string
    field :description, :string
    field :kind, Ecto.Enum, values: [:public, :private]
    field :purpose, Ecto.Enum, values: [:group, :direct], default: :group
    field :is_general, :boolean, default: false
    field :archived_at, :utc_datetime

    belongs_to :owner, ElixirChat.Accounts.User

    has_many :messages, ElixirChat.Chat.Message
    has_one :direct_conversation, ElixirChat.Chat.DirectConversation
    has_many :memberships, ElixirChat.Chat.ChannelMembership

    many_to_many :members, ElixirChat.Accounts.User,
      join_through: ElixirChat.Chat.ChannelMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :kind, :purpose, :owner_id, :is_general, :archived_at])
    |> validate_required([:name, :kind, :purpose])
    |> validate_format(:name, ~r/^[a-z0-9-]+$/)
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:description, max: 500)
    |> foreign_key_constraint(:owner_id)
    |> unique_constraint(:name)
  end

  def group_changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :kind])
    |> put_change(:purpose, :group)
    |> validate_required([:name, :kind, :purpose])
    |> validate_inclusion(:kind, [:public, :private])
    |> validate_format(:name, ~r/^[a-z0-9-]+$/)
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
  end
end
