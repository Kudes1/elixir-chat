defmodule ElixirChatWeb.PageControllerTest do
  use ElixirChatWeb.ConnCase

  alias ElixirChat.Chat.Channel
  alias ElixirChat.Repo

  test "GET / redirects guests to login", %{conn: conn} do
    Repo.insert!(Channel.changeset(%Channel{}, %{name: "general", kind: :public}))

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/login"
  end

  test "GET / redirects an authenticated user to the empty state when no channel exists", %{
    conn: conn
  } do
    conn = conn |> log_in_user(register_user()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/channels"
  end
end
