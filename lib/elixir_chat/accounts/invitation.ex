defmodule ElixirChat.Accounts.Invitation do
  use Ecto.Schema

  schema "invitations" do
    field :kind, Ecto.Enum, values: [:user_registration, :admin_bootstrap, :password_reset]
    field :token_hash, :binary
    field :login, :string
    field :display_name, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :user, ElixirChat.Accounts.User
    belongs_to :created_by, ElixirChat.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
