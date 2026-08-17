defmodule ElixirChat.Notifications.PushSubscription do
  @moduledoc "A browser Web Push subscription owned by a user."

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, min: 1)
    |> validate_length(:p256dh, min: 1)
    |> validate_length(:auth, min: 1)
    |> unique_constraint([:user_id, :endpoint], name: :push_subscriptions_user_id_endpoint_index)
  end
end
