defmodule ElixirChat.Notifications.PushSubscription do
  @moduledoc "A browser Web Push subscription owned by a user."

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User
  alias ElixirChat.Notifications.EndpointPolicy

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, min: 1, max: 2_048)
    |> validate_length(:p256dh, min: 1, max: 512)
    |> validate_length(:auth, min: 1, max: 256)
    |> EndpointPolicy.validate(:endpoint)
    |> unique_constraint(:endpoint, name: :push_subscriptions_endpoint_index)
  end
end
