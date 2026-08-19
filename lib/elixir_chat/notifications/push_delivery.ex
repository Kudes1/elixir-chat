defmodule ElixirChat.Notifications.PushDelivery do
  @moduledoc "A durable Web Push delivery attempt for one subscription and message."

  use Ecto.Schema

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.Message
  alias ElixirChat.Notifications.PushSubscription

  schema "push_deliveries" do
    field :payload, :map

    belongs_to :subscription, PushSubscription
    belongs_to :recipient, User
    belongs_to :message, Message

    timestamps(type: :utc_datetime)
  end
end
