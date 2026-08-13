defmodule ElixirChatWeb.AdminSessionController do
  use ElixirChatWeb, :controller
  alias ElixirChat.Accounts.User
  def new(conn, _), do: render(conn, :new, form: Phoenix.Component.to_form(%{}, as: :sudo))

  def create(conn, %{"sudo" => %{"password" => password}}) do
    if User.valid_password?(conn.assigns.current_scope.user, password) do
      conn |> put_session(:sudo_at, System.system_time(:second)) |> redirect(to: ~p"/admin/users")
    else
      conn |> put_flash(:error, "Неверный пароль.") |> redirect(to: ~p"/admin/reauth")
    end
  end
end
