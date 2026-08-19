defmodule ElixirChat.Notifications.Notification do
  @moduledoc """
  A durable notification: the source of truth for "this recipient needs to
  know about this message", independent of `PushDelivery` (which is only a
  record of one delivery attempt over one transport). Created atomically with
  the message in the same `Ecto.Multi` as `ElixirChat.Chat.persist_message_transaction/4`,
  so it can never exist without the message it refers to nor be silently
  dropped by a crash between the two writes.

  Deliberately narrow: only for `@mention` (parsed from the body against the
  channel's current recipients) and `direct_message` (a DM is always
  notification-worthy today). Regular channel messages to non-mentioned
  members do not get a row here — that is the whole point of this table
  existing separately from "every message, every recipient".
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.{Channel, Message}

  @types ~w(mention direct_message)

  schema "notifications" do
    field :type, :string

    belongs_to :recipient, User
    belongs_to :message, Message
    belongs_to :channel, Channel

    timestamps(type: :utc_datetime)
  end

  def types, do: @types

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:type, :recipient_id, :message_id, :channel_id])
    |> validate_required([:type, :recipient_id, :message_id, :channel_id])
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:recipient_id)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:channel_id)
    |> unique_constraint([:message_id, :recipient_id, :type])
  end
end
