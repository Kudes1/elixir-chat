defmodule ElixirChatWeb.SessionControllerTest do
  use ElixirChatWeb.ConnCase

  import Ecto.Query

  alias ElixirChat.Accounts.UserToken
  alias ElixirChat.Repo

  @session_cookie "_elixir_chat_key"
  @session_max_age 60 * 60 * 24 * 30

  test "login creates a persistent 30-day session cookie", %{conn: conn} do
    user = register_user(%{login: "persistent.user"})

    conn =
      post(conn, ~p"/login", %{
        "user" => %{"login" => user.login, "password" => "long-test-password"}
      })

    assert redirected_to(conn) == ~p"/"
    assert get_resp_cookies(conn)[@session_cookie].max_age == @session_max_age
    assert get_session(conn, :session_persistence_version) == 1
  end

  test "an existing authenticated session is upgraded to a persistent cookie", %{conn: conn} do
    user = register_user(%{login: "existing.session.user"})
    conn = log_in_user(conn, user)

    conn = get(conn, ~p"/")

    assert get_session(conn, :session_persistence_version) == 1
    assert get_resp_cookies(conn)[@session_cookie].max_age == @session_max_age
  end

  test "an authenticated page load renews a session near its renewal threshold", %{conn: conn} do
    user = register_user(%{login: "renewed.user"})
    conn = log_in(conn, user)
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(token in UserToken, where: token.user_id == ^user.id),
      set: [expires_at: DateTime.add(now, 28, :day)]
    )

    conn = conn |> recycle() |> get(~p"/")
    renewed_token = Repo.one!(from token in UserToken, where: token.user_id == ^user.id)

    assert DateTime.compare(renewed_token.expires_at, DateTime.add(now, 29, :day)) == :gt
    assert get_resp_cookies(conn)[@session_cookie].max_age == @session_max_age
  end

  test "logout revokes the server token and drops the persistent cookie", %{conn: conn} do
    user = register_user(%{login: "logout.user"})

    conn = conn |> log_in(user) |> recycle() |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/login"
    refute Repo.exists?(from token in UserToken, where: token.user_id == ^user.id)
    assert get_resp_cookies(conn)[@session_cookie].max_age == 0
  end

  defp log_in(conn, user) do
    post(conn, ~p"/login", %{
      "user" => %{"login" => user.login, "password" => "long-test-password"}
    })
  end
end
