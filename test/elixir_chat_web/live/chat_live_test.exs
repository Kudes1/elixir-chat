defmodule ElixirChatWeb.ChatLiveTest do
  use ElixirChatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ElixirChat.Accounts
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
    {:ok, view, _html} = live(conn, ~p"/channels/#{general.public_id}")
    assert has_element?(view, "#channel-#{general.id}.selected")

    view |> element("#channel-#{product.id}") |> render_click()
    assert_patch(view, ~p"/channels/#{product.public_id}")
    assert has_element?(view, "#channel-#{product.id}.selected")
  end

  test "sends and receives a persisted message", %{conn: conn, general: general, user: user} do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/channels/#{general.public_id}")

    view
    |> form("#message-form", message: %{body: "  Новое сообщение  "})
    |> render_submit()

    assert has_element?(view, ".message-list article p", "Новое сообщение")
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

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#message-login-#{first.id}", "@#{user.login}")
    assert has_element?(view, "#message-login-#{second.id}", "@other.user")
  end

  test "groups consecutive messages from one user under one author header", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, first} = Chat.create_message(Scope.for_user(user), general, %{body: "Первое"})
    {:ok, second} = Chat.create_message(Scope.for_user(user), general, %{body: "Второе"})
    avatar_class = ".avatar-variant-#{rem(user.id, 4)}"

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#messages-#{first.id} .message-avatar#{avatar_class}", "И")
    assert has_element?(view, "#message-login-#{first.id}", "@#{user.login}")
    assert has_element?(view, "#messages-#{second.id}.message-continuation")
    assert has_element?(view, "#messages-#{second.id} .message-continuation-time")
    refute has_element?(view, "#messages-#{second.id} .message-avatar")
    refute has_element?(view, "#message-login-#{second.id}")
    assert has_element?(view, "#current-user .profile-avatar#{avatar_class}", "И")
  end

  test "starts a new author header after another user writes", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "oleg"})
    {:ok, first} = Chat.create_message(Scope.for_user(user), general, %{body: "Первое"})
    {:ok, second} = Chat.create_message(Scope.for_user(other_user), general, %{body: "Ответ"})
    {:ok, third} = Chat.create_message(Scope.for_user(user), general, %{body: "Третье"})

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    for message <- [first, second, third] do
      refute has_element?(view, "#messages-#{message.id}.message-continuation")
      assert has_element?(view, "#messages-#{message.id} .message-avatar")
    end
  end

  test "groups a new consecutive message without duplicating its stream item", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, first} = Chat.create_message(Scope.for_user(user), general, %{body: "Первое"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    view
    |> form("#message-form", message: %{body: "Второе"})
    |> render_submit()

    [persisted_first, second] = Chat.list_messages(general.id)
    assert persisted_first.id == first.id
    assert has_element?(view, "#messages-#{second.id}.message-continuation")
    assert has_element?(view, "#messages-#{second.id} .message-continuation-time")
    refute has_element?(view, "#messages-#{second.id} .message-avatar")
  end

  test "keeps a group intact across the older-messages page boundary", %{
    conn: conn,
    general: general,
    user: user
  } do
    messages =
      for number <- 1..51 do
        {:ok, message} =
          Chat.create_message(Scope.for_user(user), general, %{body: "Сообщение #{number}"})

        message
      end

    [oldest, boundary | _rest] = messages
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    refute has_element?(view, "#messages-#{oldest.id}")
    refute has_element?(view, "#messages-#{boundary.id}.message-continuation")

    render_hook(view, "load_older_messages", %{})

    assert has_element?(view, "#messages-#{oldest.id} .message-avatar")
    assert has_element?(view, "#messages-#{boundary.id}.message-continuation")
    refute has_element?(view, "#messages-#{boundary.id} .message-avatar")
  end

  test "bounds the message DOM and paginates in both directions", %{
    conn: conn,
    general: general,
    user: user
  } do
    messages =
      for number <- 1..201 do
        {:ok, message} =
          Chat.create_message(Scope.for_user(user), general, %{body: "Окно #{number}"})

        message
      end

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    for _page <- 1..3, do: render_hook(view, "load_older_messages", %{})

    assert message_element_count(view) == 150
    assert has_element?(view, "#messages-#{Enum.at(messages, 1).id}")
    refute has_element?(view, "#messages-#{List.last(messages).id}")

    render_hook(view, "load_newer_messages", %{})

    assert message_element_count(view) == 150
    refute has_element?(view, "#messages-#{Enum.at(messages, 1).id}")
    assert has_element?(view, "#messages-#{List.last(messages).id}")
  end

  test "holds realtime messages outside an historical window and jumps to latest", %{
    conn: conn,
    general: general,
    user: user
  } do
    messages =
      for number <- 1..151 do
        {:ok, message} =
          Chat.create_message(Scope.for_user(user), general, %{body: "История #{number}"})

        message
      end

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    for _page <- 1..3, do: render_hook(view, "load_older_messages", %{})

    other_user = register_user(%{display_name: "Олег", login: "realtime.user"})

    {:ok, realtime_message} =
      Chat.create_message(Scope.for_user(other_user), general, %{body: "Новое в realtime"})

    assert has_element?(view, "#jump-to-latest", "Новые сообщения")
    refute has_element?(view, "#messages-#{realtime_message.id}")
    assert message_element_count(view) == 150

    view |> element("#jump-to-latest") |> render_click()

    assert has_element?(view, "#messages-#{realtime_message.id}", "Новое в realtime")
    refute has_element?(view, "#jump-to-latest")
    refute has_element?(view, "#messages-#{List.first(messages).id}")
  end

  test "clears the new-messages banner once every message beyond the window is gone", %{
    conn: conn,
    general: general,
    user: user
  } do
    for number <- 1..151 do
      Chat.create_message(Scope.for_user(user), general, %{body: "История #{number}"})
    end

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    for _page <- 1..3, do: render_hook(view, "load_older_messages", %{})

    # Loading all the way to the start evicts the window's newest boundary one
    # message short of the real latest, leaving exactly one pre-existing
    # message ("leftover") stranded beyond it.
    [leftover] = Chat.list_messages(general.id) |> Enum.take(-1)

    other_user = register_user(%{display_name: "Олег", login: "banner.watcher"})

    {:ok, realtime_message} =
      Chat.create_message(Scope.for_user(other_user), general, %{body: "Пропадёт"})

    assert has_element?(view, "#jump-to-latest", "Новые сообщения")

    Chat.delete_message(Scope.for_user(other_user), realtime_message.id)
    render(view)

    # The leftover message still exists beyond the window, so the banner is
    # correctly still warranted.
    assert has_element?(view, "#jump-to-latest")

    Chat.delete_message(Scope.for_user(user), leftover.id)
    render(view)

    refute has_element?(view, "#jump-to-latest")
  end

  test "deleting a message the viewer never loaded does not corrupt the sliding window", %{
    conn: conn,
    general: general,
    user: user
  } do
    for number <- 1..155 do
      Chat.create_message(Scope.for_user(user), general, %{body: "Окно #{number}"})
    end

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    for _page <- 1..3, do: render_hook(view, "load_older_messages", %{})

    other_user = register_user(%{display_name: "Олег", login: "window.watcher"})

    {:ok, pending_message} =
      Chat.create_message(Scope.for_user(other_user), general, %{body: "Никогда не увидят"})

    assert has_element?(view, "#jump-to-latest", "Новые сообщения")
    refute has_element?(view, "#messages-#{pending_message.id}")

    Chat.delete_message(Scope.for_user(other_user), pending_message.id)
    render(view)

    render_hook(view, "load_newer_messages", %{})
    render_hook(view, "load_older_messages", %{})

    assert message_element_count(view) == 150
  end

  test "renders the redesigned localized sidebar and current user profile", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#chat-sidebar")
    assert has_element?(view, "#workspace-brand", "Рабочее пространство")
    assert has_element?(view, "#workspace-brand", "Orbit")
    assert has_element?(view, "#channel-navigation[aria-label='Навигация чата']", "Каналы")

    assert has_element?(
             view,
             "#chat-sidebar.sidebar-sections-pending[phx-hook='SidebarSections']"
           )

    assert has_element?(
             view,
             "#channels-toggle[aria-expanded='true'][aria-controls='channel-list']"
           )

    assert has_element?(
             view,
             "#direct-messages-toggle[aria-expanded='true'][aria-controls='direct-messages-content']"
           )

    assert has_element?(view, "#open-direct-search[aria-label='Начать личный диалог']")
    assert has_element?(view, "#current-user .profile-avatar", "И")
    assert has_element?(view, "#current-user-login", "@#{user.login}")
    refute has_element?(view, ".workspace-sidebar")
    refute has_element?(view, ".workspace-mark")
  end

  test "renders accessible mobile sidebar controls", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(
             view,
             "#sidebar-toggle[aria-controls='chat-sidebar'][aria-expanded='false'][phx-click]"
           )

    assert has_element?(view, "#sidebar-overlay[aria-label='Закрыть навигацию'][phx-click]")
    assert has_element?(view, "#chat-sidebar[phx-window-keydown][phx-key='escape']")
  end

  test "uses Russian labels for conversation controls", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "section[aria-label='Канал general']")
    assert has_element?(view, ".online-indicator", "в сети")
    assert has_element?(view, "#message-body[aria-label='Сообщение']")
    assert has_element?(view, "#send-message[aria-label='Отправить сообщение']")
  end

  test "clicking an author login pushes the mention to the composer", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Привет"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

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

    {:ok, view, html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#messages-#{message.id} .message-mention", "@other.user")
    assert html =~ "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute html =~ "<script>alert"
  end

  test "renders a historical message without a user", %{
    conn: conn,
    general: general,
    user: user
  } do
    first =
      %Message{channel_id: general.id}
      |> Message.historical_changeset(%{author_name: "Архив", body: "Старое сообщение"})
      |> Repo.insert!()

    second =
      %Message{channel_id: general.id}
      |> Message.historical_changeset(%{author_name: "Архив", body: "Ещё одно сообщение"})
      |> Repo.insert!()

    avatar_class = ".avatar-variant-#{:erlang.phash2("архив", 4)}"

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#messages-#{first.id} .message-avatar#{avatar_class}", "А")
    assert has_element?(view, "#messages-#{second.id}.message-continuation")
    refute has_element?(view, "#messages-#{second.id} .message-avatar")
    refute has_element?(view, "#message-login-#{first.id}")
    refute has_element?(view, "#message-login-#{second.id}")
  end

  test "a numeric channel URL no longer resolves", %{
    conn: conn,
    general: general,
    user: user
  } do
    conn = log_in_user(conn, user)
    assert {:error, {:live_redirect, redirect}} = live(conn, ~p"/channels/#{general.id}")
    assert redirect.to == ~p"/channels/#{general.public_id}"
    assert redirect.flash["error"] == "Канал не найден. Открыт основной канал."
  end

  test "searches for a user and opens an idempotent direct conversation", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "oleg.direct"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    view |> element("#open-direct-search") |> render_click()
    assert has_element?(view, "#direct-search-panel")

    view
    |> form("#direct-search-form", direct_search: %{query: "oleg"})
    |> render_change()

    assert has_element?(view, "#direct-user-#{other_user.id}", "@oleg.direct")
    view |> element("#direct-user-#{other_user.id}") |> render_click()

    [direct] = Chat.list_direct_conversations(Scope.for_user(user))
    assert_patch(view, ~p"/direct/#{direct.channel.public_id}")
    assert has_element?(view, "#direct-conversation-#{direct.id}.selected")
    assert has_element?(view, "section[aria-label='Личный диалог с Олег']")
    assert has_element?(view, "#message-body[placeholder='Написать @oleg.direct']")

    assert {:ok, repeated} =
             Chat.get_or_create_direct_conversation(Scope.for_user(user), other_user.id)

    assert repeated.id == direct.id
  end

  test "a new direct conversation appears for the recipient in real time", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Мария", login: "maria"})
    {:ok, sender_view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    {:ok, recipient_view, _html} =
      live(log_in_user(build_conn(), other_user), ~p"/channels/#{general.public_id}")

    sender_view |> element("#open-direct-search") |> render_click()
    sender_view |> element("#direct-user-#{other_user.id}") |> render_click()
    [direct] = Chat.list_direct_conversations(Scope.for_user(user))

    render(recipient_view)
    assert has_element?(recipient_view, "#direct-conversation-#{direct.id}", user.display_name)
  end

  test "delivers direct messages to both participants without a reload", %{
    conn: conn,
    user: user
  } do
    other_user = register_user(%{display_name: "Мария", login: "maria"})

    assert {:ok, direct} =
             Chat.get_or_create_direct_conversation(Scope.for_user(user), other_user.id)

    {:ok, sender_view, _html} =
      live(log_in_user(conn, user), ~p"/direct/#{direct.channel.public_id}")

    {:ok, recipient_view, _html} =
      live(log_in_user(build_conn(), other_user), ~p"/direct/#{direct.channel.public_id}")

    sender_view
    |> form("#message-form", message: %{body: "Личное сообщение"})
    |> render_submit()

    render(recipient_view)
    assert has_element?(sender_view, ".message-list article p", "Личное сообщение")
    assert has_element?(recipient_view, ".message-list article p", "Личное сообщение")
    assert length(Chat.list_messages(direct.channel.id)) == 1
  end

  test "direct conversation history is read-only for a disabled recipient", %{
    conn: conn,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "disabled.user"})

    assert {:ok, direct} =
             Chat.get_or_create_direct_conversation(Scope.for_user(user), other_user.id)

    assert {:ok, _message} =
             Chat.create_message(Scope.for_user(user), direct.channel, %{body: "Старая история"})

    other_user
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/direct/#{direct.channel.public_id}")
    assert has_element?(view, ".message-list article p", "Старая история")
    assert has_element?(view, "#direct-recipient-disabled", "только для чтения")
    refute has_element?(view, "#message-form")
  end

  test "an outsider cannot open a direct conversation", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "oleg"})
    outsider = register_user(%{display_name: "Анна", login: "outsider"})

    assert {:ok, direct} =
             Chat.get_or_create_direct_conversation(Scope.for_user(user), other_user.id)

    assert {:error, {:live_redirect, redirect}} =
             live(log_in_user(conn, outsider), ~p"/direct/#{direct.channel.public_id}")

    assert redirect.to == ~p"/channels/#{general.public_id}"
    assert redirect.flash["error"] =~ "не найден или недоступен"
  end

  test "a numeric direct conversation URL no longer resolves", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "numeric.direct"})

    assert {:ok, direct} =
             Chat.get_or_create_direct_conversation(Scope.for_user(user), other_user.id)

    assert {:error, {:live_redirect, redirect}} =
             live(log_in_user(conn, user), ~p"/direct/#{direct.id}")

    assert redirect.to == ~p"/channels/#{general.public_id}"
    assert redirect.flash["error"] =~ "не найден или недоступен"
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
    assert has_element?(view, "#empty-chat", "Выберите разговор")
    refute has_element?(view, "#message-form")
  end

  test "opening direct conversations keeps their activity order and one selection", %{
    conn: conn,
    general: general,
    user: user
  } do
    first_user = register_user(%{display_name: "Первый", login: "first.direct"})
    second_user = register_user(%{display_name: "Второй", login: "second.direct"})
    {:ok, first} = Chat.get_or_create_direct_conversation(Scope.for_user(user), first_user.id)
    {:ok, second} = Chat.get_or_create_direct_conversation(Scope.for_user(user), second_user.id)

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    assert direct_ids(view) == [second.id, first.id]

    view |> element("#direct-conversation-#{first.id}") |> render_click()
    assert_patch(view, ~p"/direct/#{first.channel.public_id}")

    assert direct_ids(view) == [second.id, first.id]
    assert has_element?(view, "#direct-conversation-#{first.id}.selected")
    assert selected_direct_count(view) == 1

    view |> element("#direct-conversation-#{second.id}") |> render_click()
    assert_patch(view, ~p"/direct/#{second.channel.public_id}")

    assert direct_ids(view) == [second.id, first.id]
    assert has_element?(view, "#direct-conversation-#{second.id}.selected")
    refute has_element?(view, "#direct-conversation-#{first.id}.selected")
    assert selected_direct_count(view) == 1

    assert {:ok, _message} =
             Chat.create_message(Scope.for_user(user), first.channel, %{body: "Новая активность"})

    assert direct_ids(view) == [first.id, second.id]
    assert has_element?(view, "#direct-conversation-#{second.id}.selected")
    assert selected_direct_count(view) == 1
  end

  test "two tabs from one session use one presence identity", %{
    conn: conn,
    general: general,
    user: user
  } do
    conn = log_in_user(conn, user)

    {:ok, first, _html} = live(conn, ~p"/channels/#{general.public_id}")
    {:ok, second, _html} = live(conn, ~p"/channels/#{general.public_id}")
    :sys.get_state(ElixirChatWeb.Presence)

    assert %{metas: metas} =
             ElixirChatWeb.Presence.get_by_key("presence:lobby", to_string(user.id))

    assert length(metas) == 2

    GenServer.stop(first.pid)
    GenServer.stop(second.pid)
  end

  test "an active user's renamed Presence metadata refreshes and blocking disconnects", %{
    conn: conn,
    general: general,
    user: user
  } do
    admin = register_user(%{login: "presence.admin", display_name: "Администратор", role: :admin})
    ElixirChat.OnlineUsers.subscribe_count()
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    assert_receive {:online_count, _}

    assert {:ok, renamed} =
             Accounts.update_user(Scope.for_user(admin), user, %{display_name: "Новое имя"})

    assert_receive {:online_count, _}
    assert render(view) =~ "Новое имя"
    assert [%{id: id}] = ElixirChat.OnlineUsers.search("новое имя", [], 20)
    assert id == user.id

    monitor = Process.monitor(view.pid)

    assert {:ok, _blocked} =
             Accounts.update_user(Scope.for_user(admin), renamed, %{
               disabled_at: DateTime.utc_now(:second)
             })

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert_receive {:online_count, _}
    assert ElixirChat.OnlineUsers.search("новое имя", [], 20) == []
  end

  test "shows a live online status dot in the DM sidebar, dialog header, and channel members list",
       %{conn: conn, user: user} do
    other_user = register_user(%{display_name: "Олег", login: "oleg.status"})

    {:ok, channel} =
      Chat.create_channel(Scope.for_user(user), %{name: "status-room", kind: :public})

    {:ok, _channel} = Chat.join_channel(Scope.for_user(other_user), channel.id)
    {:ok, direct} = Chat.get_or_create_direct_conversation(Scope.for_user(user), other_user.id)

    ElixirChat.OnlineUsers.subscribe_count()
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/direct/#{direct.channel.public_id}")

    assert has_element?(view, "#direct-conversation-#{direct.id} .avatar-status-dot")
    refute has_element?(view, "#direct-conversation-#{direct.id} .avatar-status-dot--online")
    assert has_element?(view, ".direct-heading .avatar-status-dot")
    refute has_element?(view, ".direct-heading .avatar-status-dot--online")

    view |> element("#channel-#{channel.id}") |> render_click()
    view |> element("#open-channel-settings") |> render_click()
    assert has_element?(view, "#channel-member-#{other_user.id} .avatar-status-dot")
    refute has_element?(view, "#channel-member-#{other_user.id} .avatar-status-dot--online")

    other_conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)
    {:ok, other_view, _html} = live(other_conn, ~p"/channels/#{channel.public_id}")
    assert_receive {:online_count, _}

    wait_until(fn ->
      has_element?(view, "#channel-member-#{other_user.id} .avatar-status-dot--online")
    end)

    view |> element("#direct-conversation-#{direct.id}") |> render_click()
    assert has_element?(view, "#direct-conversation-#{direct.id} .avatar-status-dot--online")
    assert has_element?(view, ".direct-heading .avatar-status-dot--online")

    GenServer.stop(other_view.pid)
    assert_receive {:online_count, _}

    wait_until(fn ->
      not has_element?(view, "#direct-conversation-#{direct.id} .avatar-status-dot--online")
    end)
  end

  test "creates a private channel from the accessible catalog", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    view |> element("#open-channel-catalog") |> render_click()
    assert has_element?(view, "#channel-catalog[role='dialog']")

    view
    |> form("#create-channel-form",
      channel: %{name: "design-team", description: "Дизайн", kind: "private"}
    )
    |> render_submit()

    [channel] = Enum.filter(Chat.list_channels(Scope.for_user(user)), &(&1.name == "design-team"))
    assert_patch(view, ~p"/channels/#{channel.public_id}")
    assert channel.owner_id == user.id
    assert channel.kind == :private
    assert has_element?(view, "#channel-#{channel.id}.selected")
    assert has_element?(view, "#open-channel-settings")
  end

  test "joins a public channel from the catalog", %{conn: conn, general: general, user: user} do
    owner = register_user(%{display_name: "Владелец", login: "catalog.owner"})

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{
               name: "announcements",
               description: "Объявления",
               kind: :public
             })

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    refute has_element?(view, "#channel-#{channel.id}")

    view |> element("#open-channel-catalog") |> render_click()
    assert has_element?(view, "#available-channel-#{channel.id}", "Объявления")
    view |> element("#join-channel-#{channel.id}") |> render_click()

    assert_patch(view, ~p"/channels/#{channel.public_id}")
    assert has_element?(view, "#channel-#{channel.id}.selected")
    refute has_element?(view, "#channel-catalog")
    refute has_element?(view, "#leave-channel")

    view |> element("#open-channel-settings") |> render_click()
    assert has_element?(view, "#channel-details", "Объявления")
    assert has_element?(view, "#channel-details", "Публичный канал")
    assert has_element?(view, "#channel-members-title", "Участники канала")
    assert has_element?(view, "#channel-members .channel-members-heading > span", "2")
    assert has_element?(view, "#channel-member-list[role='list'][tabindex='0']")
    assert has_element?(view, "#channel-member-#{owner.id}", "администратор")
    assert has_element?(view, "#channel-member-#{user.id}")
    assert has_element?(view, "#leave-channel", "Выйти из канала")
    refute has_element?(view, "#edit-channel-form")
    refute has_element?(view, "#archive-channel")

    view |> element("#leave-channel") |> render_click()
    assert_patch(view, ~p"/channels/#{general.public_id}")
  end

  test "private invitation and owner removal update two live sessions", %{
    conn: conn,
    general: general,
    user: owner
  } do
    member = register_user(%{display_name: "Мария", login: "private.member"})

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{name: "leadership", kind: :private})

    {:ok, owner_view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")

    {:ok, member_view, _html} =
      live(log_in_user(build_conn(), member), ~p"/channels/#{general.public_id}")

    owner_view |> element("#open-channel-settings") |> render_click()

    owner_view
    |> form("#invite-search-form", invite_search: %{query: "private.member"})
    |> render_change()

    owner_view |> element("#invite-user-#{member.id}") |> render_click()
    render(member_view)
    assert has_element?(member_view, "#channel-#{channel.id}", "leadership")

    member_view |> element("#channel-#{channel.id}") |> render_click()
    assert_patch(member_view, ~p"/channels/#{channel.public_id}")

    owner_view |> element("#remove-member-#{member.id}") |> render_click()
    render(member_view)
    assert_patch(member_view, ~p"/channels/#{general.public_id}")
    refute has_element?(member_view, "#channel-#{channel.id}")
  end

  test "owner edits, transfers ownership and then leaves", %{
    conn: conn,
    general: general,
    user: owner
  } do
    member = register_user(%{display_name: "Новый владелец", login: "new.owner"})
    member_scope = Scope.for_user(member)

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{name: "old-name", kind: :private})

    assert {:ok, _} = Chat.invite_member(Scope.for_user(owner), channel, member)
    {:ok, view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")
    view |> element("#open-channel-settings") |> render_click()

    view
    |> form("#edit-channel-form",
      channel: %{name: "new-name", description: "Обновлено", kind: "private"}
    )
    |> render_submit()

    assert has_element?(view, ".channel-title", "new-name")
    view |> element("#open-channel-settings") |> render_click()
    view |> element("#transfer-owner-#{member.id}") |> render_click()
    assert {:ok, transferred} = Chat.get_channel(member_scope, channel.id)
    assert transferred.owner_id == member.id

    view |> element("#leave-channel") |> render_click()
    assert_patch(view, ~p"/channels/#{general.public_id}")
  end

  test "archiving redirects every active member and preserves the channel row", %{
    conn: conn,
    general: general,
    user: owner
  } do
    member = register_user(%{display_name: "Участник", login: "archive.member"})

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{name: "temporary", kind: :private})

    assert {:ok, _} = Chat.invite_member(Scope.for_user(owner), channel, member)
    {:ok, owner_view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")

    {:ok, member_view, _html} =
      live(log_in_user(build_conn(), member), ~p"/channels/#{channel.public_id}")

    owner_view |> element("#open-channel-settings") |> render_click()
    owner_view |> element("#archive-channel") |> render_click()
    assert_patch(owner_view, ~p"/channels/#{general.public_id}")
    render(member_view)
    assert_patch(member_view, ~p"/channels/#{general.public_id}")
    assert Repo.get!(Channel, channel.id).archived_at
  end

  test "author can delete their own recent message", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Удалю"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#message-menu-toggle-#{message.id}")
    assert has_element?(view, "#delete-message-#{message.id}", "Удалить")

    view |> element("#delete-message-#{message.id}") |> render_click()

    refute has_element?(view, "#messages-#{message.id}")
    refute Repo.get(Message, message.id)
  end

  test "the delete action carries a client-side expiry only when it is time-limited", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Скоро истечёт"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    actions =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#message-actions-#{message.id}")

    assert LazyHTML.attribute(actions, "phx-hook") == ["MessageDeleteWindow"]
    [deadline] = LazyHTML.attribute(actions, "data-delete-deadline")

    expected =
      message.inserted_at
      |> DateTime.add(Chat.delete_window(), :millisecond)
      |> DateTime.to_unix(:millisecond)

    assert_in_delta String.to_integer(deadline), expected, 2_000
  end

  test "the channel owner's permanent delete action carries no client-side expiry", %{
    conn: conn,
    user: owner
  } do
    member = register_user(%{display_name: "Участник", login: "no-expiry.member"})

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{name: "no-expiry-owned", kind: :public})

    assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)
    {:ok, message} = Chat.create_message(Scope.for_user(member), channel, %{body: "Старое"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second))
    |> Repo.update!()

    {:ok, view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")

    actions =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#message-actions-#{message.id}")

    assert has_element?(view, "#delete-message-#{message.id}")
    assert LazyHTML.attribute(actions, "phx-hook") == []
    assert LazyHTML.attribute(actions, "data-delete-deadline") == []
  end

  test "the actions menu is hidden for someone else's message", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "delete.viewer"})
    {:ok, message} = Chat.create_message(Scope.for_user(other_user), general, %{body: "Чужое"})

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    refute has_element?(view, "#message-menu-toggle-#{message.id}")
    refute has_element?(view, "#delete-message-#{message.id}")
  end

  test "channel owner can delete another member's message in their channel", %{
    conn: conn,
    user: owner
  } do
    member = register_user(%{display_name: "Участник", login: "delete.member"})

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{
               name: "owned-delete-live",
               kind: :public
             })

    assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)

    {:ok, message} =
      Chat.create_message(Scope.for_user(member), channel, %{body: "Сообщение участника"})

    {:ok, view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")
    assert has_element?(view, "#delete-message-#{message.id}")

    view |> element("#delete-message-#{message.id}") |> render_click()
    refute has_element?(view, "#messages-#{message.id}")
    refute Repo.get(Message, message.id)
  end

  test "deleting a message removes it for other viewers in real time", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "delete.watcher"})
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Всем видно"})

    {:ok, author_view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    {:ok, watcher_view, _html} =
      live(log_in_user(build_conn(), other_user), ~p"/channels/#{general.public_id}")

    author_view |> element("#delete-message-#{message.id}") |> render_click()

    render(watcher_view)
    refute has_element?(watcher_view, "#messages-#{message.id}")
  end

  test "deleting the first message of a group re-groups the remaining message under its own author",
       %{conn: conn, general: general, user: user} do
    other_user = register_user(%{display_name: "Олег", login: "regroup.other"})
    {:ok, _greeting} = Chat.create_message(Scope.for_user(other_user), general, %{body: "Привет"})
    {:ok, first} = Chat.create_message(Scope.for_user(user), general, %{body: "Первое"})
    {:ok, second} = Chat.create_message(Scope.for_user(user), general, %{body: "Второе"})

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")
    assert has_element?(view, "#messages-#{second.id}.message-continuation")

    view |> element("#delete-message-#{first.id}") |> render_click()

    refute has_element?(view, "#messages-#{first.id}")
    refute has_element?(view, "#messages-#{second.id}.message-continuation")
    assert has_element?(view, "#messages-#{second.id} .message-avatar")
    assert has_element?(view, "#message-login-#{second.id}", "@#{user.login}")
  end

  test "author can edit their own recent message", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Исходник"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -2, :second))
    |> Repo.update!()

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    assert has_element?(view, "#edit-message-#{message.id}", "Изменить")

    view |> element("#edit-message-#{message.id}") |> render_click()
    assert has_element?(view, "#edit-message-form-#{message.id}")

    view
    |> form("#edit-message-form-#{message.id}", body: "Отредактировано")
    |> render_submit()

    refute has_element?(view, "#edit-message-form-#{message.id}")
    assert has_element?(view, "#messages-#{message.id}", "Отредактировано")
    assert has_element?(view, "#messages-#{message.id} .message-edited-badge", "(изменено)")
    refute has_element?(view, "#messages-#{message.id} .message-edited-badge-hover")
    assert Repo.get!(Message, message.id).body == "Отредактировано"
  end

  test "an edited continuation message shows the edited badge only on hover", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, first} = Chat.create_message(Scope.for_user(user), general, %{body: "Первое"})
    {:ok, second} = Chat.create_message(Scope.for_user(user), general, %{body: "Второе"})

    first_inserted_at = DateTime.add(DateTime.utc_now(:second), -3, :second)
    second_inserted_at = DateTime.add(DateTime.utc_now(:second), -2, :second)

    first
    |> Ecto.Changeset.change(inserted_at: first_inserted_at, updated_at: first_inserted_at)
    |> Repo.update!()

    second
    |> Ecto.Changeset.change(inserted_at: second_inserted_at, updated_at: second_inserted_at)
    |> Repo.update!()

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    refute has_element?(view, "#messages-#{second.id} .message-edited-badge-hover")

    view |> element("#edit-message-#{second.id}") |> render_click()

    view
    |> form("#edit-message-form-#{second.id}", body: "Второе отредактировано")
    |> render_submit()

    assert has_element?(
             view,
             "#messages-#{second.id} .message-edited-badge-hover",
             "(изменено)"
           )
  end

  test "cancelling an edit leaves the message unchanged", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Исходник"})
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    view |> element("#edit-message-#{message.id}") |> render_click()
    assert has_element?(view, "#edit-message-form-#{message.id}")

    view |> element(".message-edit-cancel") |> render_click()

    refute has_element?(view, "#edit-message-form-#{message.id}")
    assert has_element?(view, "#messages-#{message.id}", "Исходник")
    refute has_element?(view, "#messages-#{message.id} .message-edited-badge")
    assert Repo.get!(Message, message.id).body == "Исходник"
  end

  test "the edit action is unavailable once the delete window has elapsed", %{
    conn: conn,
    general: general,
    user: user
  } do
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Просрочено"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second))
    |> Repo.update!()

    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    refute has_element?(view, "#edit-message-#{message.id}")
    refute has_element?(view, "#delete-message-#{message.id}")
  end

  test "the channel owner's edit action expires even though their delete action does not", %{
    conn: conn,
    user: owner
  } do
    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{
               name: "owner-expired-edit",
               kind: :public
             })

    {:ok, message} =
      Chat.create_message(Scope.for_user(owner), channel, %{body: "Просрочено"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second))
    |> Repo.update!()

    {:ok, view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")

    refute has_element?(view, "#edit-message-#{message.id}")
    assert has_element?(view, "#delete-message-#{message.id}")
  end

  test "edit action is hidden for someone else's message, including for the channel owner", %{
    conn: conn,
    user: owner
  } do
    member = register_user(%{display_name: "Участник", login: "edit.member"})

    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{name: "owned-edit-live", kind: :public})

    assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)

    {:ok, message} =
      Chat.create_message(Scope.for_user(member), channel, %{body: "Сообщение участника"})

    {:ok, view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")

    refute has_element?(view, "#edit-message-#{message.id}")
    assert has_element?(view, "#delete-message-#{message.id}")
  end

  test "the edit action carries a client-side expiry even for the channel owner's own message", %{
    conn: conn,
    user: owner
  } do
    assert {:ok, channel} =
             Chat.create_channel(Scope.for_user(owner), %{name: "owner-own-edit", kind: :public})

    {:ok, message} =
      Chat.create_message(Scope.for_user(owner), channel, %{body: "Моё сообщение"})

    {:ok, view, _html} = live(log_in_user(conn, owner), ~p"/channels/#{channel.public_id}")

    edit_button =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#edit-message-#{message.id}")

    assert LazyHTML.attribute(edit_button, "phx-hook") == ["MessageEditWindow"]
    [deadline] = LazyHTML.attribute(edit_button, "data-edit-deadline")

    expected =
      message.inserted_at
      |> DateTime.add(Chat.delete_window(), :millisecond)
      |> DateTime.to_unix(:millisecond)

    assert_in_delta String.to_integer(deadline), expected, 2_000

    delete_actions =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#message-actions-#{message.id}")

    assert LazyHTML.attribute(delete_actions, "phx-hook") == []
  end

  test "editing a message updates it for other viewers in real time", %{
    conn: conn,
    general: general,
    user: user
  } do
    other_user = register_user(%{display_name: "Олег", login: "edit.watcher"})
    {:ok, message} = Chat.create_message(Scope.for_user(user), general, %{body: "Исходник"})

    {:ok, author_view, _html} = live(log_in_user(conn, user), ~p"/channels/#{general.public_id}")

    {:ok, watcher_view, _html} =
      live(log_in_user(build_conn(), other_user), ~p"/channels/#{general.public_id}")

    author_view |> element("#edit-message-#{message.id}") |> render_click()

    author_view
    |> form("#edit-message-form-#{message.id}", body: "Обновлено для всех")
    |> render_submit()

    render(watcher_view)
    assert has_element?(watcher_view, "#messages-#{message.id}", "Обновлено для всех")
  end

  defp message_element_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".message-list article")
    |> Enum.count()
  end

  defp direct_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#direct-conversation-list > a")
    |> Enum.map(fn element ->
      element
      |> LazyHTML.attribute("id")
      |> List.first()
      |> String.replace_prefix("direct-conversation-", "")
      |> String.to_integer()
    end)
  end

  defp selected_direct_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#direct-conversation-list > a.selected")
    |> Enum.count()
  end

  defp wait_until(fun, attempts \\ 20) do
    cond do
      fun.() ->
        :ok

      attempts <= 1 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(15)
        wait_until(fun, attempts - 1)
    end
  end
end
