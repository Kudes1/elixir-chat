defmodule ElixirChatWeb.UserAuth do
  use ElixirChatWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias ElixirChat.Accounts
  alias ElixirChat.Accounts.Scope

  def log_in_user(conn, user) do
    token = Accounts.generate_session_token(user)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> redirect(to: ~p"/")
  end

  def log_out_user(conn) do
    token = get_session(conn, :user_token)

    if socket_id = get_session(conn, :live_socket_id),
      do: ElixirChatWeb.Endpoint.broadcast(socket_id, "disconnect", %{})

    Accounts.delete_session_token(token)
    conn |> configure_session(renew: true) |> clear_session() |> redirect(to: ~p"/login")
  end

  def fetch_current_scope(conn, _opts) do
    user = conn |> get_session(:user_token) |> Accounts.get_user_by_session_token()
    assign(conn, :current_scope, Scope.for_user(user))
  end

  def redirect_if_user_is_authenticated(%{assigns: %{current_scope: %Scope{}}} = conn, _opts),
    do: conn |> redirect(to: ~p"/") |> halt()

  def redirect_if_user_is_authenticated(conn, _opts), do: conn

  def require_authenticated_user(%{assigns: %{current_scope: %Scope{}}} = conn, _opts), do: conn

  def require_authenticated_user(conn, _opts),
    do:
      conn
      |> put_flash(:error, "Войдите, чтобы продолжить.")
      |> redirect(to: ~p"/login")
      |> halt()

  def require_admin(%{assigns: %{current_scope: %Scope{user: %{role: :admin}}}} = conn, _opts),
    do: conn

  def require_admin(conn, _opts), do: conn |> send_resp(:forbidden, "Forbidden") |> halt()

  def on_mount(:mount_current_scope, _params, session, socket) do
    user = Accounts.get_user_by_session_token(session["user_token"])
    {:cont, Phoenix.Component.assign_new(socket, :current_scope, fn -> Scope.for_user(user) end)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case Accounts.get_user_by_session_token(session["user_token"]) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      user ->
        socket = Phoenix.Component.assign(socket, :current_scope, Scope.for_user(user))

        {:cont,
         Phoenix.LiveView.attach_hook(socket, :session_valid, :handle_info, fn
           _, socket ->
             if Accounts.get_user_by_session_token(session["user_token"]),
               do: {:cont, socket},
               else: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
         end)}
    end
  end

  def on_mount(:ensure_admin, params, session, socket) do
    with {:cont, socket} <- on_mount(:ensure_authenticated, params, session, socket),
         %{role: :admin} <- socket.assigns.current_scope.user,
         sudo when is_integer(sudo) <- session["sudo_at"],
         true <- System.system_time(:second) - sudo < 600 do
      {:cont, socket}
    else
      {:halt, socket} -> {:halt, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/admin/reauth")}
    end
  end
end
