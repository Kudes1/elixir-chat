defmodule ElixirChatWeb.SessionController do
  use ElixirChatWeb, :controller
  alias ElixirChat.Accounts
  alias ElixirChatWeb.UserAuth

  def new(conn, _),
    do: render(conn, :new, form: Phoenix.Component.to_form(%{"login" => ""}, as: :user))

  def create(conn, %{"user" => %{"login" => login, "password" => password}}) do
    case Accounts.get_user_by_login_and_password(login, password) do
      nil -> conn |> put_flash(:error, "Неверный логин или пароль.") |> redirect(to: ~p"/login")
      user -> UserAuth.log_in_user(conn, user)
    end
  end

  def delete(conn, _), do: UserAuth.log_out_user(conn)
end
