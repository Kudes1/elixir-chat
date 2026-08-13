defmodule ElixirChat.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :login, :string
    field :display_name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :role, Ecto.Enum, values: [:user, :admin], default: :user
    field :disabled_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs, role \\ :user) do
    user
    |> cast(attrs, [:password])
    |> put_change(:login, normalize_login(attrs[:login] || attrs["login"]))
    |> put_change(:display_name, attrs[:display_name] || attrs["display_name"])
    |> put_change(:role, role)
    |> validate_required([:login, :display_name, :password])
    |> validate_format(:login, ~r/^[a-z0-9._-]+$/)
    |> validate_length(:login, min: 3, max: 32)
    |> validate_length(:display_name, min: 2, max: 80)
    |> validate_length(:password, min: 12, max: 128)
    |> unique_constraint(:login)
    |> unique_constraint(:role, name: :users_single_admin_index)
    |> hash_password()
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required(:password)
    |> validate_length(:password, min: 12, max: 128)
    |> hash_password()
  end

  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :disabled_at])
    |> validate_required(:display_name)
    |> validate_length(:display_name, min: 2, max: 80)
  end

  def valid_password?(%__MODULE__{disabled_at: nil, hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password), do: Argon2.verify_pass(password, hash)

  def valid_password?(_, _), do: Argon2.no_user_verify() && false

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset

  defp normalize_login(login) when is_binary(login),
    do: login |> String.trim() |> String.downcase()

  defp normalize_login(login), do: login
end
