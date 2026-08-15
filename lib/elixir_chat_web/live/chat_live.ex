defmodule ElixirChatWeb.ChatLive do
  use ElixirChatWeb, :live_view

  alias ElixirChat.Accounts
  alias ElixirChat.Accounts.Scope
  alias ElixirChat.Chat
  alias ElixirChat.Chat.{Channel, DirectConversation, Message}
  alias ElixirChat.OnlineUsers
  alias ElixirChatWeb.Presence

  import ElixirChatWeb.ChatLive.Components
  alias ElixirChatWeb.ChatLive.MessageWindow

  @presence_topic "presence:lobby"
  @message_page_size 50
  @message_window_size 150

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      OnlineUsers.subscribe_count()
      Chat.subscribe_user(user.id)
      Chat.subscribe_catalog()

      {:ok, _ref} =
        Presence.track(self(), @presence_topic, to_string(user.id), %{
          id: user.id,
          login: user.login,
          display_name: user.display_name,
          online_at: System.system_time(:second)
        })
    end

    direct_conversations =
      socket.assigns.current_scope
      |> Chat.list_direct_conversations()
      |> Enum.map(&direct_item(&1, user.id))

    {:ok,
     socket
     |> assign(:page_title, "Orbit")
     |> assign(:channels, Chat.list_channels(socket.assigns.current_scope))
     |> assign(:channel, nil)
     |> assign(:direct_conversation, nil)
     |> assign(:current_other_user, nil)
     |> assign(:direct_conversations, direct_conversations)
     |> assign(:subscribed_channel_id, nil)
     |> assign(:visitor_name, user.display_name)
     |> assign(:online_count, OnlineUsers.count())
     |> assign(:message_form, empty_message_form())
     |> assign(:direct_search_form, direct_search_form())
     |> assign(:direct_search_results, [])
     |> assign(:direct_search_open?, false)
     |> assign(:channel_catalog_open?, false)
     |> assign(:channel_settings_open?, false)
     |> assign(:channel_form, channel_form())
     |> assign(:available_channels, [])
     |> assign(:channel_memberships, [])
     |> assign(:invite_search_form, invite_search_form())
     |> assign(:invite_search_results, [])
     |> assign(:message_search_open?, false)
     |> assign(:message_search_form, message_search_form())
     |> assign(:message_search_results, [])
     |> assign(:message_search_cursor, nil)
     |> assign(:message_search_has_more?, false)
     |> reset_message_assigns()
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(
        %{"public_id" => public_id},
        _uri,
        %{assigns: %{live_action: :direct}} = socket
      ) do
    case Chat.get_direct_conversation_by_public_id(socket.assigns.current_scope, public_id) do
      {:ok, direct} -> {:noreply, load_direct_conversation(socket, direct)}
      {:error, :not_found} -> {:noreply, recover_from_missing_conversation(socket, :direct)}
    end
  end

  def handle_params(%{"public_id" => public_id}, _uri, socket) do
    case Chat.get_channel_by_public_id(socket.assigns.current_scope, public_id) do
      {:ok, channel} -> {:noreply, load_public_channel(socket, channel)}
      {:error, :not_found} -> {:noreply, recover_from_missing_conversation(socket, :channel)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, clear_conversation(socket)}

  @impl true
  def handle_event(
        "send_message",
        %{"message" => params},
        %{assigns: %{channel: channel}} = socket
      )
      when not is_nil(channel) do
    attrs = %{body: Map.get(params, "body", "")}

    case Chat.create_message(socket.assigns.current_scope, channel, attrs) do
      {:ok, message} ->
        socket = assign(socket, :message_form, empty_message_form())

        socket =
          if socket.assigns.at_latest? do
            MessageWindow.append_message(socket, message)
          else
            MessageWindow.load_latest_messages(socket)
          end

        {:noreply, push_event(socket, "message_sent", %{})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :message_form, to_form(changeset, as: :message))}

      {:error, :recipient_disabled} ->
        {:noreply,
         socket
         |> refresh_active_direct()
         |> put_flash(:error, "Собеседник отключён. Отправка сообщений недоступна.")}

      {:error, :forbidden} ->
        {:noreply, recover_from_missing_conversation(socket, conversation_kind(socket))}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("open_channel_catalog", _params, socket) do
    {:noreply,
     socket
     |> assign(:channel_catalog_open?, true)
     |> assign(:channel_form, channel_form())
     |> refresh_available_channels()}
  end

  def handle_event("close_channel_catalog", _params, socket),
    do: {:noreply, assign(socket, :channel_catalog_open?, false)}

  def handle_event("validate_channel", %{"channel" => params}, socket) do
    changeset = %Channel{} |> Chat.change_channel(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :channel_form, to_form(changeset))}
  end

  def handle_event("create_channel", %{"channel" => params}, socket) do
    case Chat.create_channel(socket.assigns.current_scope, params) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel_catalog_open?, false)
         |> refresh_channels()
         |> push_patch(to: ~p"/channels/#{channel.public_id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :channel_form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось создать канал.")}
    end
  end

  def handle_event("join_channel", %{"channel-id" => channel_id}, socket) do
    case Chat.join_channel(socket.assigns.current_scope, channel_id) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel_catalog_open?, false)
         |> refresh_channels()
         |> push_patch(to: ~p"/channels/#{channel.public_id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось вступить в канал.")}
    end
  end

  def handle_event("open_channel_settings", _params, %{assigns: %{channel: channel}} = socket)
      when not is_nil(channel) do
    {:noreply,
     socket
     |> assign(:channel_settings_open?, true)
     |> assign(:channel_form, to_form(Chat.change_channel(channel)))
     |> assign(:invite_search_form, invite_search_form())
     |> assign(:invite_search_results, [])
     |> refresh_memberships()}
  end

  def handle_event("close_channel_settings", _params, socket),
    do: {:noreply, assign(socket, :channel_settings_open?, false)}

  def handle_event("update_channel", %{"channel" => params}, socket) do
    case Chat.update_channel(socket.assigns.current_scope, socket.assigns.channel, params) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> assign(:channel_settings_open?, false)
         |> refresh_channels()
         |> put_flash(:info, "Канал обновлён.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :channel_form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("leave_channel", _params, socket) do
    case Chat.leave_channel(socket.assigns.current_scope, socket.assigns.channel) do
      {:ok, _channel} -> {:noreply, recover_from_missing_conversation(socket, :left_channel)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("archive_channel", _params, socket) do
    case Chat.archive_channel(socket.assigns.current_scope, socket.assigns.channel) do
      {:ok, _channel} -> {:noreply, recover_from_missing_conversation(socket, :archived_channel)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("search_invitable_users", %{"invite_search" => %{"query" => query}}, socket) do
    results =
      Chat.search_invitable_users(socket.assigns.current_scope, socket.assigns.channel, query, 20)

    {:noreply,
     socket
     |> assign(:invite_search_form, invite_search_form(query))
     |> assign(:invite_search_results, results)}
  end

  def handle_event("invite_member", %{"user-id" => user_id}, socket) do
    case Chat.invite_member(socket.assigns.current_scope, socket.assigns.channel, user_id) do
      {:ok, _channel} ->
        {:noreply,
         socket
         |> refresh_memberships()
         |> assign(:invite_search_results, [])
         |> put_flash(:info, "Участник добавлен.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    case Chat.remove_member(socket.assigns.current_scope, socket.assigns.channel, user_id) do
      {:ok, _channel} -> {:noreply, refresh_memberships(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("transfer_ownership", %{"user-id" => user_id}, socket) do
    case Chat.transfer_ownership(socket.assigns.current_scope, socket.assigns.channel, user_id) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> refresh_memberships()
         |> refresh_channels()
         |> put_flash(:info, "Владелец канала изменён.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("open_direct_search", _params, socket) do
    results = Accounts.search_messageable_users(socket.assigns.current_scope, "", 20)

    {:noreply,
     socket
     |> assign(:direct_search_open?, true)
     |> assign(:direct_search_form, direct_search_form())
     |> assign(:direct_search_results, results)}
  end

  def handle_event("close_direct_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:direct_search_open?, false)
     |> assign(:direct_search_form, direct_search_form())
     |> assign(:direct_search_results, [])}
  end

  def handle_event("search_direct_users", %{"direct_search" => %{"query" => query}}, socket) do
    results = Accounts.search_messageable_users(socket.assigns.current_scope, query, 20)

    {:noreply,
     socket
     |> assign(:direct_search_form, direct_search_form(query))
     |> assign(:direct_search_results, results)}
  end

  def handle_event("start_direct", %{"user-id" => user_id}, socket) do
    case Chat.get_or_create_direct_conversation(socket.assigns.current_scope, user_id) do
      {:ok, direct} ->
        {:noreply,
         socket
         |> assign(:direct_search_open?, false)
         |> assign(:direct_search_results, [])
         |> upsert_direct(direct, false)
         |> push_patch(to: ~p"/direct/#{direct.channel.public_id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось открыть личный диалог.")}
    end
  end

  def handle_event("insert_mention", %{"login" => login}, socket) do
    {:noreply, push_event(socket, "insert_mention", %{mention: "@#{login}"})}
  end

  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns do
      %{channel: channel, has_older_messages?: true, oldest_message: %Message{} = oldest} ->
        {messages, has_older_messages?} =
          MessageWindow.fetch_messages_before(socket, channel.id, oldest, @message_page_size)

        {:noreply, MessageWindow.prepend_messages(socket, messages, oldest, has_older_messages?)}

      _ ->
        {:noreply, push_event(socket, "older_messages_loaded", %{})}
    end
  end

  def handle_event("load_newer_messages", _params, socket) do
    case socket.assigns do
      %{channel: channel, has_newer_messages?: true, newest_message: %Message{} = newest} ->
        {messages, has_newer_messages?} =
          MessageWindow.fetch_messages_after(socket, channel.id, newest, @message_page_size)

        {:noreply, MessageWindow.append_newer_messages(socket, messages, has_newer_messages?)}

      _ ->
        {:noreply, push_event(socket, "newer_messages_loaded", %{})}
    end
  end

  def handle_event("jump_to_latest", _params, socket) do
    {:noreply, MessageWindow.load_latest_messages(socket)}
  end

  def handle_event("open_message_search", _params, socket) do
    {:noreply, assign(socket, :message_search_open?, true)}
  end

  def handle_event("close_message_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:message_search_open?, false)
     |> assign(:message_search_form, message_search_form())
     |> assign(:message_search_results, [])
     |> assign(:message_search_cursor, nil)
     |> assign(:message_search_has_more?, false)}
  end

  def handle_event("search_messages", %{"message_search" => %{"query" => query}}, socket) do
    case Chat.search_messages(socket.assigns.current_scope, socket.assigns.channel.id, query, nil) do
      {:ok, {messages, has_more?}} ->
        {:noreply,
         socket
         |> assign(:message_search_form, message_search_form(query))
         |> assign(:message_search_results, messages)
         |> assign(:message_search_cursor, List.last(messages))
         |> assign(:message_search_has_more?, has_more?)}

      {:error, :not_found} ->
        {:noreply, recover_from_missing_conversation(socket, conversation_kind(socket))}
    end
  end

  def handle_event("load_more_message_results", _params, socket) do
    query = socket.assigns.message_search_form[:query].value || ""

    case Chat.search_messages(
           socket.assigns.current_scope,
           socket.assigns.channel.id,
           query,
           socket.assigns.message_search_cursor
         ) do
      {:ok, {messages, has_more?}} ->
        {:noreply,
         socket
         |> update(:message_search_results, &(&1 ++ messages))
         |> assign(
           :message_search_cursor,
           List.last(messages) || socket.assigns.message_search_cursor
         )
         |> assign(:message_search_has_more?, has_more?)}

      {:error, :not_found} ->
        {:noreply, recover_from_missing_conversation(socket, conversation_kind(socket))}
    end
  end

  def handle_event("jump_to_message", %{"message-id" => message_id}, socket) do
    case Chat.message_window(
           socket.assigns.current_scope,
           socket.assigns.channel.id,
           message_id,
           @message_window_size
         ) do
      {:ok, {messages, has_older?, has_newer?}} ->
        target = Enum.find(messages, &(to_string(&1.id) == to_string(message_id)))

        {:noreply,
         socket
         |> assign(:oldest_message, List.first(messages))
         |> assign(:newest_message, List.last(messages))
         |> assign(:message_count, length(messages))
         |> assign(:has_older_messages?, has_older?)
         |> assign(:has_newer_messages?, has_newer?)
         |> assign(:at_latest?, !has_newer?)
         |> assign(:pending_new_messages?, false)
         |> assign(:highlighted_message_id, target && target.id)
         |> assign(:message_search_open?, false)
         |> stream(:messages, MessageWindow.message_items(messages), reset: true)
         |> push_event("scroll_to_message", %{id: "messages-#{message_id}"})}

      {:error, :not_found} ->
        {:noreply, MessageWindow.load_latest_messages(socket)}
    end
  end

  @impl true
  def handle_info({:message_created, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, MessageWindow.receive_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:direct_conversation_updated, %DirectConversation{} = direct}, socket) do
    {:noreply, upsert_direct(socket, direct, true)}
  end

  def handle_info(
        {:direct_message_created, %DirectConversation{} = direct, %Message{} = message},
        socket
      ) do
    socket = upsert_direct(socket, direct, true)

    if socket.assigns.direct_conversation &&
         socket.assigns.direct_conversation.id == direct.id do
      {:noreply, MessageWindow.receive_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:channels_changed, channel_id}, socket) do
    socket = socket |> refresh_channels() |> refresh_available_channels_if_open()

    if socket.assigns.channel && is_nil(socket.assigns.direct_conversation) &&
         socket.assigns.channel.id == channel_id do
      case Chat.get_channel(socket.assigns.current_scope, channel_id) do
        {:ok, channel} ->
          {:noreply, socket |> assign(:channel, channel) |> refresh_memberships_if_open()}

        {:error, :not_found} ->
          {:noreply, recover_from_missing_conversation(socket, :channel_access_changed)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:catalog_changed, _channel_id}, socket) do
    {:noreply, refresh_available_channels_if_open(socket)}
  end

  def handle_info({:online_count, count}, socket) do
    {:noreply, assign(socket, :online_count, count)}
  end

  def handle_info({:user_presence_updated, user}, socket) do
    current_user = socket.assigns.current_scope.user

    if user.id == current_user.id do
      if is_nil(user.disabled_at) do
        {:ok, _ref} =
          Presence.update(self(), @presence_topic, to_string(user.id), %{
            id: user.id,
            login: user.login,
            display_name: user.display_name,
            online_at: System.system_time(:second)
          })
      end

      {:noreply,
       socket
       |> assign(:current_scope, Scope.for_user(user))
       |> assign(:visitor_name, user.display_name)}
    else
      {:noreply, socket}
    end
  end

  defp load_public_channel(socket, channel),
    do: MessageWindow.load_conversation(socket, channel, nil)

  defp load_direct_conversation(socket, direct) do
    socket
    |> upsert_direct(direct, false)
    |> MessageWindow.load_conversation(direct.channel, direct)
  end

  defp recover_from_missing_conversation(socket, kind) do
    message =
      if kind == :direct,
        do: "Личный диалог не найден или недоступен. Открыт основной канал.",
        else: "Канал не найден. Открыт основной канал."

    case Chat.get_default_channel(socket.assigns.current_scope) do
      {:ok, channel} ->
        socket
        |> put_flash(:error, message)
        |> push_patch(to: ~p"/channels/#{channel.public_id}")

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Пока нет доступных разговоров.")
        |> push_patch(to: ~p"/channels")
    end
  end

  defp clear_conversation(socket) do
    if connected?(socket) && socket.assigns.subscribed_channel_id do
      Phoenix.PubSub.unsubscribe(
        ElixirChat.PubSub,
        Chat.topic(socket.assigns.subscribed_channel_id)
      )
    end

    socket
    |> assign(:page_title, "Orbit")
    |> assign(:channel, nil)
    |> assign(:direct_conversation, nil)
    |> assign(:current_other_user, nil)
    |> assign(:subscribed_channel_id, nil)
    |> assign(:channel_settings_open?, false)
    |> reset_message_assigns()
    |> stream(:messages, [], reset: true)
  end

  defp reset_message_assigns(socket) do
    socket
    |> assign(:oldest_message, nil)
    |> assign(:newest_message, nil)
    |> assign(:message_count, 0)
    |> assign(:has_older_messages?, false)
    |> assign(:has_newer_messages?, false)
    |> assign(:at_latest?, true)
    |> assign(:pending_new_messages?, false)
  end

  defp refresh_active_direct(%{assigns: %{direct_conversation: nil}} = socket), do: socket

  defp refresh_active_direct(socket) do
    case Chat.get_direct_conversation(
           socket.assigns.current_scope,
           socket.assigns.direct_conversation.id
         ) do
      {:ok, direct} -> upsert_direct(socket, direct, false)
      {:error, :not_found} -> socket
    end
  end

  defp upsert_direct(socket, direct, move_to_front?) do
    item = direct_item(direct, socket.assigns.current_scope.user.id)
    existing_index = Enum.find_index(socket.assigns.direct_conversations, &(&1.id == direct.id))

    direct_conversations =
      cond do
        is_nil(existing_index) ->
          [item | socket.assigns.direct_conversations] |> Enum.take(50)

        move_to_front? ->
          [item | Enum.reject(socket.assigns.direct_conversations, &(&1.id == direct.id))]
          |> Enum.take(50)

        true ->
          List.replace_at(socket.assigns.direct_conversations, existing_index, item)
      end

    socket = assign(socket, :direct_conversations, direct_conversations)

    case socket.assigns.direct_conversation do
      %DirectConversation{id: id} when id == direct.id ->
        socket
        |> assign(:direct_conversation, direct)
        |> assign(:current_other_user, item.other_user)

      _other ->
        socket
    end
  end

  defp direct_item(direct, current_user_id) do
    %{
      id: direct.id,
      public_id: direct.channel.public_id,
      direct: direct,
      other_user: DirectConversation.other_user(direct, current_user_id)
    }
  end

  def other_user(nil, _current_user_id), do: nil

  def other_user(direct, current_user_id),
    do: DirectConversation.other_user(direct, current_user_id)

  defp conversation_kind(%{assigns: %{direct_conversation: nil}}), do: :channel
  defp conversation_kind(_socket), do: :direct

  def conversation_title(channel, nil, _current_user_id), do: "##{channel.name} · Orbit"

  def conversation_title(_channel, direct, current_user_id),
    do: "#{DirectConversation.other_user(direct, current_user_id).display_name} · Orbit"

  defp refresh_channels(socket),
    do: assign(socket, :channels, Chat.list_channels(socket.assigns.current_scope))

  defp refresh_available_channels(socket) do
    assign(
      socket,
      :available_channels,
      Chat.list_available_public_channels(socket.assigns.current_scope)
    )
  end

  defp refresh_available_channels_if_open(%{assigns: %{channel_catalog_open?: true}} = socket),
    do: refresh_available_channels(socket)

  defp refresh_available_channels_if_open(socket), do: socket

  defp refresh_memberships(%{assigns: %{channel: %Channel{} = channel}} = socket) do
    case Chat.list_channel_memberships(socket.assigns.current_scope, channel) do
      {:ok, memberships} -> assign(socket, :channel_memberships, memberships)
      {:error, _reason} -> assign(socket, :channel_memberships, [])
    end
  end

  defp refresh_memberships(socket), do: assign(socket, :channel_memberships, [])

  defp refresh_memberships_if_open(%{assigns: %{channel_settings_open?: true}} = socket),
    do: refresh_memberships(socket)

  defp refresh_memberships_if_open(socket), do: socket

  defp channel_error(:protected_channel), do: "Основной канал защищён от этого действия."
  defp channel_error(:owner_must_transfer), do: "Сначала передайте владение другому участнику."
  defp channel_error(:forbidden), do: "Недостаточно прав для этого действия."
  defp channel_error(:not_member), do: "Пользователь не является участником канала."
  defp channel_error(:invalid_target), do: "Нельзя передать владение этому пользователю."
  defp channel_error(_reason), do: "Не удалось изменить канал."

  def empty_message_form, do: to_form(%{"body" => ""}, as: :message)
  defp direct_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :direct_search)
  defp invite_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :invite_search)
  def message_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :message_search)

  defp channel_form do
    %Channel{kind: :public, purpose: :group}
    |> Chat.change_channel()
    |> to_form()
  end

end
