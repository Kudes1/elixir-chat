defmodule ElixirChat.Accounts.UserToken do
  use Ecto.Schema

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :authenticated_at, :utc_datetime
    field :expires_at, :utc_datetime
    belongs_to :user, ElixirChat.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
