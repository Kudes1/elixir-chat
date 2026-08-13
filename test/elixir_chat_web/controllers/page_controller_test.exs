defmodule ElixirChatWeb.PageControllerTest do
  use ElixirChatWeb.ConnCase

  alias ElixirChat.Chat.Channel
  alias ElixirChat.Repo

  test "GET / redirects to general and creates a stable guest session", %{conn: conn} do
    channel = Repo.insert!(Channel.changeset(%Channel{}, %{name: "general", kind: :public}))

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/channels/#{channel.id}"
    assert is_binary(get_session(conn, :guest_id))
    assert get_session(conn, :visitor_name) =~ "Гость "
  end

  test "GET / redirects to the empty state when no public channel exists", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/channels"
  end
end
