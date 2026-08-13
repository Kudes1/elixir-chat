defmodule ElixirChatWeb.ChatLiveTest do
  use ElixirChatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ElixirChat.Chat
  alias ElixirChat.Chat.Channel
  alias ElixirChat.Chat.Message
  alias ElixirChat.Accounts.Scope
  alias ElixirChat.Repo

  setup do
    general = Repo.insert!(Channel.changeset(%Channel{}, %{name: "general", kind: :public}))
    product = Repo.insert!(Channel.changeset(%Channel{}, %{name: "product", kind: :public}))
    user = register_user(%{display_name: "Ирина"})
    %{general: general, product: product, user: user}
  end

  test "opens and switches channels through patch navigation", %{
    conn: conn,
    general: general,
    product: product,
    user: user
  } do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/channels/#{general.id}")
    assert has_element?(view, "#channel-#{general.id}.selected")

    view |> element("#channel-#{product.id}") |> render_click()
    assert_patch(view, ~p"/channels/#{product.id}")
    assert has_element?(view, "#channel-#{product.id}.selected")
  end

  test "sends and receives a persisted message", %{conn: conn, general: general, user: user} do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/channels/#{general.id}")

    view
    |> form("#message-form", message: %{body: "  Новое сообщение  "})
    |> render_submit()

    assert has_element?(view, "#messages article p", "Новое сообщение")
    assert [message] = Chat.list_messages(general.id)
    assert message.body == "Новое сообщение"
  end

  test "shows distinct logins beside identical display names", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: user.display_name, login: "other.user"})
    {:ok, first} = Chat.create_message(Scope.for_user(user), general, %{body: "Первое"})
    {:ok, second} = Chat.create_message(Scope.for_user(other_user), general, %{body: "Второе"})

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.id}")

    assert has_element?(view, "#message-login-#{first.id}", "@#{user.login}")
    assert has_element?(view, "#message-login-#{second.id}", "@other.user")
  end

  test "shows the current user's login in the sidebar", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.id}")

    assert has_element?(view, "#current-user-login", "@#{user.login}")
  end

  test "clicking an author login pushes the mention to the composer", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Привет"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.id}")

    view |> element("#message-login-#{message.id}") |> render_click()
    expected_mention = "@#{user.login}"
    assert_push_event(view, "insert_mention", %{mention: ^expected_mention})
  end

  test "highlights mentions while preserving and escaping ordinary text", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} =
      Chat.create_message(Scope.for_user(user), general, %{
        body: "Привет @other.user <script>alert('x')</script>"
      })

    {:ok, view, html} = live(log_in_user(conn, user), ~p"/channels/#{general.id}")

    assert has_element?(view, "#messages-#{message.id} .message-mention", "@other.user")
    assert html =~ "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute html =~ "<script>alert"
  end

  test "renders a historical message without a user", %{
    conn: conn,
    general: general,
    user: user
  } do
    message =
      %Message{channel_id: general.id}
      |> Message.historical_changeset(%{author_name: "Архив", body: "Старое сообщение"})
      |> Repo.insert!()

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.id}")

    assert has_element?(view, "#messages-#{message.id}", "Архив")
    refute has_element?(view, "#message-login-#{message.id}")
  end

  test "invalid channel recovers to general without crashing", %{
    conn: conn,
    general: general,
    user: user
  } do
    conn = log_in_user(conn, user)
    assert {:error, {:live_redirect, redirect}} = live(conn, ~p"/channels/999999")
    assert redirect.to == ~p"/channels/#{general.id}"
    assert redirect.flash["error"] == "Канал не найден. Открыт основной канал."
  end

  test "empty state is rendered without channels", %{
    conn: conn,
    general: general,
    product: product,
    user: user
  } do
    Repo.delete!(general)
    Repo.delete!(product)

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels")
    assert has_element?(view, "#empty-chat", "Пока нет доступных каналов")
    refute has_element?(view, "#message-form")
  end

  test "two tabs from one session use one presence identity", %{
    conn: conn,
    general: general,
    user: user
  } do
    conn = log_in_user(conn, user)

    {:ok, first, _html} = live(conn, ~p"/channels/#{general.id}")
    {:ok, second, _html} = live(conn, ~p"/channels/#{general.id}")
    :sys.get_state(ElixirChatWeb.Presence)

    assert %{metas: metas} =
             ElixirChatWeb.Presence.get_by_key("presence:lobby", to_string(user.id))

    assert length(metas) == 2

    GenServer.stop(first.pid)
    GenServer.stop(second.pid)
  end
end
