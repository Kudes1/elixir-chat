defmodule ElixirChat.Chat.ConversationRead do
  @moduledoc "A durable per-user read cursor for a conversation."

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.Channel

  schema "conversation_reads" do
    field :last_read_at, :utc_datetime
    field :last_read_message_id, :integer

    belongs_to :user, User
    belongs_to :channel, Channel

    timestamps(type: :utc_datetime)
  end

  def changeset(read, attrs) do
    read
    |> cast(attrs, [:user_id, :channel_id, :last_read_at, :last_read_message_id])
    |> validate_required([:user_id, :channel_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:channel_id)
    |> unique_constraint([:user_id, :channel_id])
  end
end
