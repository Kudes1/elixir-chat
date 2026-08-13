defmodule ElixirChatWeb.ChatLiveTest do
  use ElixirChatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ElixirChat.Chat
  alias ElixirChat.Chat.Channel
  alias ElixirChat.Repo

  setup do
    general = Repo.insert!(Channel.changeset(%Channel{}, %{name: "general", kind: :public}))
    product = Repo.insert!(Channel.changeset(%Channel{}, %{name: "product", kind: :public}))
    %{general: general, product: product}
  end

  test "opens and switches channels through patch navigation", %{
    conn: conn,
    general: general,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/channels/#{general.id}")
    assert has_element?(view, "#channel-#{general.id}.selected")

    view |> element("#channel-#{product.id}") |> render_click()
    assert_patch(view, ~p"/channels/#{product.id}")
    assert has_element?(view, "#channel-#{product.id}.selected")
  end

  test "sends and receives a persisted message", %{conn: conn, general: general} do
    {:ok, view, _html} = live(conn, ~p"/channels/#{general.id}")

    view
    |> form("#message-form", message: %{body: "  Новое сообщение  "})
    |> render_submit()

    assert has_element?(view, "#messages article p", "Новое сообщение")
    assert [message] = Chat.list_messages(general.id)
    assert message.body == "Новое сообщение"
  end

  test "invalid channel recovers to general without crashing", %{conn: conn, general: general} do
    assert {:error, {:live_redirect, redirect}} = live(conn, ~p"/channels/999999")
    assert redirect.to == ~p"/channels/#{general.id}"
    assert redirect.flash["error"] == "Канал не найден. Открыт основной канал."
  end

  test "empty state is rendered without channels", %{
    conn: conn,
    general: general,
    product: product
  } do
    Repo.delete!(general)
    Repo.delete!(product)

    {:ok, view, _html} = live(conn, ~p"/channels")
    assert has_element?(view, "#empty-chat", "Пока нет доступных каналов")
    refute has_element?(view, "#message-form")
  end

  test "two tabs from one session use one presence identity", %{conn: conn, general: general} do
    conn = get(conn, ~p"/")
    guest_id = get_session(conn, :guest_id)

    {:ok, first, _html} = live(conn, ~p"/channels/#{general.id}")
    {:ok, second, _html} = live(conn, ~p"/channels/#{general.id}")
    :sys.get_state(ElixirChatWeb.Presence)

    assert %{metas: metas} = ElixirChatWeb.Presence.get_by_key("presence:lobby", guest_id)
    assert length(metas) == 2

    GenServer.stop(first.pid)
    GenServer.stop(second.pid)
  end
end
