defmodule ElixirChat.Notifications.PushDelivery do
  @moduledoc "A durable Web Push delivery attempt for one subscription and message."

  use Ecto.Schema

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.Message
  alias ElixirChat.Notifications.PushSubscription

  schema "push_deliveries" do
    field :payload, :map
    field :attempt_count, :integer, default: 0
    field :available_at, :utc_datetime
    field :last_error, :string

    belongs_to :subscription, PushSubscription
    belongs_to :recipient, User
    belongs_to :message, Message

    timestamps(type: :utc_datetime)
  end
end
