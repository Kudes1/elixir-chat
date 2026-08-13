defmodule ElixirChatWeb.InvitationController do
  use ElixirChatWeb, :controller
  alias ElixirChat.Accounts

  def capture(conn, %{"token" => token}) do
    case Accounts.get_invitation(token) do
      {:ok, _} ->
        conn |> put_session(:invitation_token, token) |> redirect(to: ~p"/invitation")

      _ ->
        conn
        |> put_flash(:error, "Ссылка недействительна или истекла.")
        |> redirect(to: ~p"/login")
    end
  end

  def new(conn, _) do
    case Accounts.get_invitation(get_session(conn, :invitation_token)) do
      {:ok, invitation} ->
        render(conn, :new,
          invitation: invitation,
          form: Phoenix.Component.to_form(%{}, as: :account)
        )

      _ ->
        conn
        |> delete_session(:invitation_token)
        |> put_flash(:error, "Ссылка недействительна или истекла.")
        |> redirect(to: ~p"/login")
    end
  end

  def create(conn, %{
        "account" => %{"password" => password, "password_confirmation" => confirmation}
      }) do
    if password == confirmation do
      case Accounts.accept_invitation(get_session(conn, :invitation_token), password) do
        {:ok, _user} ->
          conn
          |> delete_session(:invitation_token)
          |> put_flash(:info, "Пароль сохранён. Теперь войдите.")
          |> redirect(to: ~p"/login")

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :new,
            invitation: nil,
            form: Phoenix.Component.to_form(changeset, as: :account)
          )

        _ ->
          conn
          |> delete_session(:invitation_token)
          |> put_flash(:error, "Ссылка недействительна или уже использована.")
          |> redirect(to: ~p"/login")
      end
    else
      conn |> put_flash(:error, "Пароли не совпадают.") |> redirect(to: ~p"/invitation")
    end
  end
end
