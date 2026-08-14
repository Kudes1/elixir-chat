defmodule ElixirChatWeb.ChatLive do
  use ElixirChatWeb, :live_view

  alias ElixirChat.Accounts
  alias ElixirChat.Chat
  alias ElixirChat.Chat.{Channel, DirectConversation, Message}
  alias ElixirChatWeb.Presence
  alias Phoenix.LiveView.JS

  @presence_topic "presence:lobby"
  @message_page_size 50
  @message_window_size 150

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElixirChat.PubSub, @presence_topic)
      Chat.subscribe_user(user.id)
      Chat.subscribe_catalog()

      {:ok, _ref} =
        Presence.track(self(), @presence_topic, to_string(user.id), %{
          name: user.display_name,
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
     |> assign(:online_count, presence_count())
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
            append_message(socket, message)
          else
            load_latest_messages(socket)
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
          fetch_messages_before(socket, channel.id, oldest, @message_page_size)

        {:noreply, prepend_messages(socket, messages, oldest, has_older_messages?)}

      _ ->
        {:noreply, push_event(socket, "older_messages_loaded", %{})}
    end
  end

  def handle_event("load_newer_messages", _params, socket) do
    case socket.assigns do
      %{channel: channel, has_newer_messages?: true, newest_message: %Message{} = newest} ->
        {messages, has_newer_messages?} =
          fetch_messages_after(socket, channel.id, newest, @message_page_size)

        {:noreply, append_newer_messages(socket, messages, has_newer_messages?)}

      _ ->
        {:noreply, push_event(socket, "newer_messages_loaded", %{})}
    end
  end

  def handle_event("jump_to_latest", _params, socket) do
    {:noreply, load_latest_messages(socket)}
  end

  @impl true
  def handle_info({:message_created, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, receive_message(socket, message)}
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
      {:noreply, receive_message(socket, message)}
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

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online_count, presence_count())}
  end

  defp load_public_channel(socket, channel), do: load_conversation(socket, channel, nil)

  defp load_direct_conversation(socket, direct) do
    socket
    |> upsert_direct(direct, false)
    |> load_conversation(direct.channel, direct)
  end

  defp load_conversation(socket, channel, direct) do
    old_channel_id = socket.assigns.subscribed_channel_id
    new_channel_id = if is_nil(direct), do: channel.id, else: nil

    if connected?(socket) && new_channel_id && old_channel_id != new_channel_id do
      Chat.subscribe(new_channel_id)
    end

    if connected?(socket) && old_channel_id && old_channel_id != new_channel_id do
      Phoenix.PubSub.unsubscribe(ElixirChat.PubSub, Chat.topic(old_channel_id))
    end

    socket
    |> assign(
      :page_title,
      conversation_title(channel, direct, socket.assigns.current_scope.user.id)
    )
    |> assign(:channel, channel)
    |> assign(:direct_conversation, direct)
    |> assign(:current_other_user, other_user(direct, socket.assigns.current_scope.user.id))
    |> assign(:subscribed_channel_id, new_channel_id)
    |> assign(:message_form, empty_message_form())
    |> load_latest_messages()
  end

  defp load_latest_messages(%{assigns: %{channel: nil}} = socket), do: socket

  defp load_latest_messages(socket) do
    {messages, has_older_messages?} =
      fetch_recent_messages(socket, socket.assigns.channel.id, @message_page_size)

    socket
    |> assign(:oldest_message, List.first(messages))
    |> assign(:newest_message, List.last(messages))
    |> assign(:message_count, length(messages))
    |> assign(:has_older_messages?, has_older_messages?)
    |> assign(:has_newer_messages?, false)
    |> assign(:at_latest?, true)
    |> assign(:pending_new_messages?, false)
    |> stream(:messages, message_items(messages), reset: true)
    |> push_event("scroll_to_latest", %{})
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
          [item | socket.assigns.direct_conversations]

        move_to_front? ->
          [item | Enum.reject(socket.assigns.direct_conversations, &(&1.id == direct.id))]

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

  defp receive_message(%{assigns: %{at_latest?: true}} = socket, message),
    do: append_message(socket, message)

  defp receive_message(socket, _message), do: assign(socket, :pending_new_messages?, true)

  defp append_message(%{assigns: %{newest_message: %Message{id: id}}} = socket, %Message{id: id}),
    do: socket

  defp append_message(socket, message) do
    previous_message = socket.assigns.newest_message
    overflow = max(socket.assigns.message_count + 1 - @message_window_size, 0)

    new_oldest =
      advance_oldest(
        socket.assigns.current_scope,
        socket.assigns.channel.id,
        socket.assigns.oldest_message,
        overflow
      )

    socket
    |> assign(:oldest_message, new_oldest || message)
    |> assign(:newest_message, message)
    |> assign(:message_count, min(socket.assigns.message_count + 1, @message_window_size))
    |> stream_insert(:messages, message_item(message, previous_message),
      limit: -@message_window_size
    )
    |> reset_first_message_group(new_oldest, overflow)
  end

  defp prepend_messages(socket, [], _oldest, has_older_messages?) do
    socket
    |> assign(:has_older_messages?, has_older_messages?)
    |> push_event("older_messages_loaded", %{})
  end

  defp prepend_messages(socket, messages, oldest, has_older_messages?) do
    count = min(socket.assigns.message_count + length(messages), @message_window_size)
    overflow = max(socket.assigns.message_count + length(messages) - @message_window_size, 0)
    new_oldest = List.first(messages)

    {newest_message, has_newer_messages?} =
      if overflow > 0 do
        {after_oldest, has_more?} =
          fetch_messages_after(
            socket,
            socket.assigns.channel.id,
            new_oldest,
            @message_window_size - 1
          )

        {List.last(after_oldest) || new_oldest, has_more?}
      else
        {socket.assigns.newest_message, socket.assigns.has_newer_messages?}
      end

    socket
    |> assign(:oldest_message, new_oldest)
    |> assign(:newest_message, newest_message)
    |> assign(:message_count, count)
    |> assign(:has_older_messages?, has_older_messages?)
    |> assign(:has_newer_messages?, has_newer_messages?)
    |> assign(:at_latest?, !has_newer_messages?)
    |> stream(:messages, messages |> message_items() |> Enum.reverse(),
      at: 0,
      limit: @message_window_size
    )
    |> stream_insert(:messages, message_item(oldest, List.last(messages)))
    |> push_event("older_messages_loaded", %{})
  end

  defp append_newer_messages(socket, [], has_newer_messages?) do
    socket
    |> assign(:has_newer_messages?, has_newer_messages?)
    |> assign(:at_latest?, !has_newer_messages?)
    |> assign(:pending_new_messages?, has_newer_messages? && socket.assigns.pending_new_messages?)
    |> push_event("newer_messages_loaded", %{})
  end

  defp append_newer_messages(socket, messages, has_newer_messages?) do
    previous_message = socket.assigns.newest_message
    overflow = max(socket.assigns.message_count + length(messages) - @message_window_size, 0)

    new_oldest =
      advance_oldest(
        socket.assigns.current_scope,
        socket.assigns.channel.id,
        socket.assigns.oldest_message,
        overflow
      )

    socket
    |> assign(:oldest_message, new_oldest || List.first(messages))
    |> assign(:newest_message, List.last(messages))
    |> assign(
      :message_count,
      min(socket.assigns.message_count + length(messages), @message_window_size)
    )
    |> assign(:has_older_messages?, true)
    |> assign(:has_newer_messages?, has_newer_messages?)
    |> assign(:at_latest?, !has_newer_messages?)
    |> assign(:pending_new_messages?, has_newer_messages? && socket.assigns.pending_new_messages?)
    |> stream(:messages, message_items(messages, previous_message), limit: -@message_window_size)
    |> reset_first_message_group(new_oldest, overflow)
    |> push_event("newer_messages_loaded", %{})
  end

  defp advance_oldest(_scope, _channel_id, oldest, 0), do: oldest
  defp advance_oldest(_scope, _channel_id, nil, _count), do: nil

  defp advance_oldest(scope, channel_id, oldest, count) do
    {:ok, {messages, _has_more?}} =
      Chat.list_messages_after(scope, channel_id, oldest, count)

    List.last(messages) || oldest
  end

  defp reset_first_message_group(socket, nil, _overflow), do: socket
  defp reset_first_message_group(socket, _message, 0), do: socket

  defp reset_first_message_group(socket, message, _overflow) do
    stream_insert(socket, :messages, message_item(message, nil))
  end

  defp message_items(messages, previous_message \\ nil) do
    messages
    |> Enum.map_reduce(previous_message, fn message, previous ->
      {message_item(message, previous), message}
    end)
    |> elem(0)
  end

  defp message_item(message, previous_message) do
    %{id: message.id, message: message, continuation?: same_author?(message, previous_message)}
  end

  defp same_author?(%Message{user_id: user_id}, %Message{user_id: user_id})
       when not is_nil(user_id),
       do: true

  defp same_author?(
         %Message{user_id: nil, author_name: author_name},
         %Message{user_id: nil, author_name: author_name}
       ),
       do: true

  defp same_author?(_message, _previous_message), do: false

  defp direct_item(direct, current_user_id) do
    %{
      id: direct.id,
      public_id: direct.channel.public_id,
      direct: direct,
      other_user: DirectConversation.other_user(direct, current_user_id)
    }
  end

  defp other_user(nil, _current_user_id), do: nil

  defp other_user(direct, current_user_id),
    do: DirectConversation.other_user(direct, current_user_id)

  defp conversation_kind(%{assigns: %{direct_conversation: nil}}), do: :channel
  defp conversation_kind(_socket), do: :direct

  defp conversation_title(channel, nil, _current_user_id), do: "##{channel.name} · Orbit"

  defp conversation_title(_channel, direct, current_user_id),
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

  defp fetch_recent_messages(socket, id, size) do
    {:ok, page} = Chat.list_recent_messages(socket.assigns.current_scope, id, size)
    page
  end

  defp fetch_messages_before(socket, id, cursor, size) do
    {:ok, page} = Chat.list_messages_before(socket.assigns.current_scope, id, cursor, size)
    page
  end

  defp fetch_messages_after(socket, id, cursor, size) do
    {:ok, page} = Chat.list_messages_after(socket.assigns.current_scope, id, cursor, size)
    page
  end

  defp channel_error(:protected_channel), do: "Основной канал защищён от этого действия."
  defp channel_error(:owner_must_transfer), do: "Сначала передайте владение другому участнику."
  defp channel_error(:forbidden), do: "Недостаточно прав для этого действия."
  defp channel_error(:not_member), do: "Пользователь не является участником канала."
  defp channel_error(:invalid_target), do: "Нельзя передать владение этому пользователю."
  defp channel_error(_reason), do: "Не удалось изменить канал."

  defp empty_message_form, do: to_form(%{"body" => ""}, as: :message)
  defp direct_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :direct_search)
  defp invite_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :invite_search)

  defp channel_form do
    %Channel{kind: :public, purpose: :group}
    |> Chat.change_channel()
    |> to_form()
  end

  defp presence_count, do: Presence.list(@presence_topic) |> map_size()

  defp open_sidebar(js \\ %JS{}) do
    js
    |> JS.show(to: "#sidebar-overlay")
    |> JS.add_class("sidebar-open", to: "#chat-sidebar")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#sidebar-toggle")
    |> JS.focus_first(to: "#chat-sidebar")
  end

  defp close_sidebar(js \\ %JS{}) do
    js
    |> JS.hide(to: "#sidebar-overlay")
    |> JS.remove_class("sidebar-open", to: "#chat-sidebar")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#sidebar-toggle")
  end

  attr :channels, :list, required: true
  attr :channel, :any, required: true
  attr :direct_conversation_id, :integer, default: nil
  attr :direct_conversations, :list, required: true
  attr :direct_search_open?, :boolean, required: true
  attr :direct_search_form, :any, required: true
  attr :direct_search_results, :list, required: true
  attr :channel_catalog_open?, :boolean, required: true
  attr :current_user, :any, required: true
  attr :visitor_name, :string, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside
      id="chat-sidebar"
      class="chat-sidebar sidebar-sections-pending"
      phx-hook="SidebarSections"
      phx-window-keydown={close_sidebar()}
      phx-key="escape"
      aria-label="Навигация чата"
    >
      <header id="workspace-brand" class="sidebar-brand">
        <p class="sidebar-eyebrow">Рабочее пространство</p>
        <h1>Orbit</h1>
      </header>
      <nav id="channel-navigation" class="channel-navigation" aria-label="Навигация чата">
        <section id="channels-section" class="sidebar-section">
          <div class="sidebar-section-header">
            <button
              id="channels-toggle"
              type="button"
              class="sidebar-section-toggle"
              data-sidebar-toggle="channels"
              aria-expanded="true"
              aria-controls="channel-list"
            >
              <.icon name="hero-chevron-down" class="sidebar-section-chevron size-3" />
              <span class="sidebar-section-title">Каналы</span>
            </button>
            <button
              id="open-channel-catalog"
              type="button"
              class="sidebar-section-action"
              phx-click="open_channel_catalog"
              aria-label="Открыть каталог каналов"
              aria-expanded={to_string(@channel_catalog_open?)}
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
          </div>
          <div id="channel-list" class="channel-list" data-sidebar-content="channels">
            <.link
              :for={channel <- @channels}
              id={"channel-#{channel.id}"}
              class={[
                "channel-link",
                @channel && is_nil(@direct_conversation_id) && channel.id == @channel.id && "selected"
              ]}
              patch={~p"/channels/#{channel.public_id}"}
              phx-click={close_sidebar()}
            >
              <span aria-hidden="true">#</span><span class="channel-name">{channel.name}</span>
            </.link>
          </div>
        </section>
        <section id="direct-messages-section" class="sidebar-section direct-messages-section">
          <div class="sidebar-section-header">
            <button
              id="direct-messages-toggle"
              type="button"
              class="sidebar-section-toggle"
              data-sidebar-toggle="directs"
              aria-expanded="true"
              aria-controls="direct-messages-content"
            >
              <.icon name="hero-chevron-down" class="sidebar-section-chevron size-3" />
              <span class="sidebar-section-title">Личные сообщения</span>
            </button>
            <button
              id="open-direct-search"
              type="button"
              class="sidebar-section-action"
              data-open-direct-search
              phx-click="open_direct_search"
              aria-label="Начать личный диалог"
              title="Начать личный диалог"
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
          </div>
          <div id="direct-messages-content" data-sidebar-content="directs">
            <div :if={@direct_search_open?} id="direct-search-panel" class="direct-search-panel">
              <div class="direct-search-heading">
                <strong>Новый диалог</strong>
                <button
                  id="close-direct-search"
                  type="button"
                  phx-click="close_direct_search"
                  aria-label="Закрыть поиск"
                ><.icon name="hero-x-mark" class="size-4" /></button>
              </div>
              <.form
                for={@direct_search_form}
                id="direct-search-form"
                phx-change="search_direct_users"
              >
                <.input
                  field={@direct_search_form[:query]}
                  id="direct-search-query"
                  type="search"
                  label="Поиск пользователя"
                  placeholder="Имя или @логин"
                  autocomplete="off"
                  phx-debounce="200"
                  phx-mounted={JS.focus()}
                />
              </.form>
              <div id="direct-search-results" class="direct-search-results">
                <button
                  :for={user <- @direct_search_results}
                  id={"direct-user-#{user.id}"}
                  type="button"
                  class="direct-user-result"
                  phx-click="start_direct"
                  phx-value-user-id={user.id}
                >
                  <.user_avatar name={user.display_name} user_id={user.id} class="direct-avatar" />
                  <span><strong>{user.display_name}</strong><small>@{user.login}</small></span>
                </button>
                <p :if={@direct_search_results == []} class="direct-search-empty">
                  Пользователи не найдены
                </p>
              </div>
            </div>
            <div id="direct-conversation-list" class="channel-list direct-conversation-list">
              <.link
                :for={item <- @direct_conversations}
                :key={item.id}
                id={"direct-conversation-#{item.id}"}
                class={["channel-link direct-link", item.id == @direct_conversation_id && "selected"]}
                patch={~p"/direct/#{item.public_id}"}
                phx-click={close_sidebar()}
              >
                <.user_avatar
                  name={item.other_user.display_name}
                  user_id={item.other_user.id}
                  class="direct-avatar"
                />
                <span class="direct-link-details">
                  <strong>{item.other_user.display_name}</strong>
                  <small>@{item.other_user.login}<span :if={item.other_user.disabled_at}> · отключён</span></small>
                </span>
              </.link>
            </div>
            <p class="direct-list-empty">Пока нет личных диалогов</p>
          </div>
        </section>
      </nav>
      <footer id="current-user" class="sidebar-profile">
        <.user_avatar name={@visitor_name} user_id={@current_user.id} class="profile-avatar" />
        <div class="profile-details">
          <strong>{@visitor_name}</strong><small id="current-user-login" class="current-user-login">@{@current_user.login}</small>
        </div>
        <.link
          href={~p"/logout"}
          method="delete"
          id="logout-link"
          class="logout-link"
          aria-label="Выйти из Orbit"
        >Выйти</.link>
      </footer>
    </aside>
    """
  end

  attr :channel, :any, required: true
  attr :other_user, :any, default: nil
  attr :online_count, :integer, required: true
  attr :current_user, :any, required: true

  defp conversation_header(assigns) do
    ~H"""
    <header class="conversation-header">
      <button
        id="sidebar-toggle"
        type="button"
        class="mobile-sidebar-toggle"
        aria-label="Открыть навигацию"
        aria-controls="chat-sidebar"
        aria-expanded="false"
        phx-click={open_sidebar()}
      >
        <.icon name="hero-bars-3" class="size-5" />
      </button>
      <%= if @other_user do %>
        <div class="channel-heading direct-heading">
          <.user_avatar
            name={@other_user.display_name}
            user_id={@other_user.id}
            class="header-avatar"
          />
          <div>
            <h2 class="channel-title">{@other_user.display_name}</h2><p>
              @{@other_user.login}<span :if={@other_user.disabled_at}> · пользователь отключён</span>
            </p>
          </div>
        </div>
      <% else %>
        <div class="channel-heading">
          <h2 class="channel-title"><span aria-hidden="true">#</span> {@channel.name}</h2><p>
            {@channel.description || "Командный разговор"}
          </p>
        </div>
      <% end %>
      <div class="channel-header-actions">
        <span class="online-indicator"><i></i>{@online_count} в сети</span>
        <button
          :if={is_nil(@other_user)}
          id="open-channel-settings"
          type="button"
          class="channel-action"
          phx-click="open_channel_settings"
          aria-label="Настройки канала"
        ><.icon name="hero-cog-6-tooth" class="size-5" /></button>
      </div>
    </header>
    """
  end

  attr :form, :any, required: true
  attr :channels, :list, required: true

  defp channel_catalog(assigns) do
    ~H"""
    <div
      id="channel-catalog"
      class="channel-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="channel-catalog-title"
    >
      <section class="channel-modal" phx-window-keydown="close_channel_catalog" phx-key="escape">
        <header>
          <h2 id="channel-catalog-title">Каталог каналов</h2>
          <button
            id="close-channel-catalog"
            type="button"
            phx-click="close_channel_catalog"
            aria-label="Закрыть каталог"
          ><.icon name="hero-x-mark" class="size-5" /></button>
        </header>
        <.form
          for={@form}
          id="create-channel-form"
          phx-change="validate_channel"
          phx-submit="create_channel"
        >
          <.input
            field={@form[:name]}
            id="new-channel-name"
            label="Название"
            placeholder="team-updates"
            autocomplete="off"
          />
          <.input
            field={@form[:description]}
            id="new-channel-description"
            label="Описание"
            type="textarea"
          />
          <.input
            field={@form[:kind]}
            id="new-channel-kind"
            label="Доступ"
            type="select"
            options={[{"Публичный", :public}, {"Приватный", :private}]}
          />
          <button id="create-channel" type="submit" class="channel-primary-action">Создать канал</button>
        </.form>
        <div id="available-channel-list" class="available-channel-list">
          <article :for={channel <- @channels} id={"available-channel-#{channel.id}"}>
            <div>
              <strong>#{channel.name}</strong><p>{channel.description || "Без описания"}</p>
            </div>
            <button
              id={"join-channel-#{channel.id}"}
              type="button"
              phx-click="join_channel"
              phx-value-channel-id={channel.id}
            >Вступить</button>
          </article>
          <p :if={@channels == []} id="available-channels-empty">Нет новых публичных каналов.</p>
        </div>
      </section>
    </div>
    """
  end

  attr :channel, :any, required: true
  attr :current_user, :any, required: true
  attr :form, :any, required: true
  attr :memberships, :list, required: true
  attr :invite_form, :any, required: true
  attr :invite_results, :list, required: true

  defp channel_settings(assigns) do
    ~H"""
    <div
      id="channel-settings"
      class="channel-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="channel-settings-title"
    >
      <section class="channel-modal" phx-window-keydown="close_channel_settings" phx-key="escape">
        <header>
          <h2 id="channel-settings-title">Настройки #<span>{@channel.name}</span></h2>
          <button
            id="close-channel-settings"
            type="button"
            phx-click="close_channel_settings"
            aria-label="Закрыть настройки"
          ><.icon name="hero-x-mark" class="size-5" /></button>
        </header>
        <section
          :if={@channel.owner_id != @current_user.id}
          id="channel-details"
          class="channel-details"
          aria-label="Информация о канале"
        >
          <div>
            <strong>Описание</strong>
            <p>{@channel.description || "Описание не добавлено"}</p>
          </div>
          <div>
            <strong>Доступ</strong>
            <p>{if @channel.kind == :public, do: "Публичный канал", else: "Приватный канал"}</p>
          </div>
        </section>
        <.form
          :if={@channel.owner_id == @current_user.id}
          for={@form}
          id="edit-channel-form"
          phx-submit="update_channel"
        >
          <.input
            field={@form[:name]}
            id="edit-channel-name"
            label="Название"
            disabled={@channel.is_general}
          />
          <.input
            field={@form[:description]}
            id="edit-channel-description"
            label="Описание"
            type="textarea"
          />
          <.input
            field={@form[:kind]}
            id="edit-channel-kind"
            label="Доступ"
            type="select"
            disabled={@channel.is_general}
            options={[{"Публичный", :public}, {"Приватный", :private}]}
          />
          <button id="update-channel" type="submit" class="channel-primary-action">Сохранить</button>
        </.form>
        <div :if={@channel.kind == :private} id="channel-invite-panel">
          <.form for={@invite_form} id="invite-search-form" phx-change="search_invitable_users">
            <.input
              field={@invite_form[:query]}
              id="invite-search-query"
              type="search"
              label="Добавить участника"
              placeholder="Имя или @логин"
              phx-debounce="200"
              autocomplete="off"
            />
          </.form>
          <button
            :for={user <- @invite_results}
            id={"invite-user-#{user.id}"}
            type="button"
            class="member-row"
            phx-click="invite_member"
            phx-value-user-id={user.id}
          >{user.display_name} <small>@{user.login}</small></button>
        </div>
        <section
          id="channel-members"
          class="channel-members-section"
          aria-labelledby="channel-members-title"
        >
          <header class="channel-members-heading">
            <h3 id="channel-members-title">Участники канала</h3>
            <span>{length(@memberships)}</span>
          </header>
          <div
            id="channel-member-list"
            class="channel-member-list"
            role="list"
            aria-label="Список участников канала"
            tabindex="0"
          >
            <div
              :for={membership <- @memberships}
              id={"channel-member-#{membership.user.id}"}
              class="channel-member-row"
              role="listitem"
            >
              <.user_avatar
                name={membership.user.display_name}
                user_id={membership.user.id}
                class="channel-member-avatar"
              />
              <span class="channel-member-identity">
                <strong>{membership.user.display_name}</strong>
                <small>@{membership.user.login}</small>
              </span>
              <em :if={membership.user.id == @channel.owner_id}>администратор</em>
              <div
                :if={@channel.owner_id == @current_user.id && membership.user.id != @current_user.id}
                class="channel-member-actions"
              >
                <button
                  id={"transfer-owner-#{membership.user.id}"}
                  type="button"
                  phx-click="transfer_ownership"
                  phx-value-user-id={membership.user.id}
                  data-confirm="Передать владение этим каналом?"
                  title="Передать владение"
                  aria-label={"Передать владение пользователю #{membership.user.display_name}"}
                ><.icon name="hero-key" class="size-4" /></button>
                <button
                  :if={@channel.kind == :private}
                  id={"remove-member-#{membership.user.id}"}
                  type="button"
                  phx-click="remove_member"
                  phx-value-user-id={membership.user.id}
                  data-confirm="Удалить участника из канала?"
                  title="Удалить из канала"
                  aria-label={"Удалить пользователя #{membership.user.display_name} из канала"}
                ><.icon name="hero-user-minus" class="size-4" /></button>
              </div>
            </div>
          </div>
        </section>
        <button
          :if={@channel.owner_id != @current_user.id && !@channel.is_general}
          id="leave-channel"
          type="button"
          class="channel-danger-action"
          phx-click="leave_channel"
          data-confirm="Покинуть этот канал?"
        >Выйти из канала</button>
        <button
          :if={@channel.owner_id == @current_user.id && !@channel.is_general}
          id="archive-channel"
          type="button"
          class="channel-danger-action"
          phx-click="archive_channel"
          data-confirm="Архивировать канал? История сохранится, но доступ будет закрыт."
        >Архивировать канал</button>
      </section>
    </div>
    """
  end

  attr :item, :map, required: true

  defp message(assigns) do
    ~H"""
    <article
      id={"messages-#{@item.id}"}
      class={["message", @item.continuation? && "message-continuation"]}
    >
      <.user_avatar
        :if={!@item.continuation?}
        name={@item.message.author_name}
        user_id={@item.message.user_id}
        class="message-avatar"
      />
      <time :if={@item.continuation?} class="message-continuation-time">{relative_time(
        @item.message.inserted_at
      )}</time>
      <div class="message-content">
        <div :if={!@item.continuation?} class="message-meta">
          <strong>{@item.message.author_name}</strong>
          <button
            :if={@item.message.user}
            id={"message-login-#{@item.message.id}"}
            type="button"
            class="message-author-login"
            phx-click="insert_mention"
            phx-value-login={@item.message.user.login}
            aria-label={"Упомянуть @#{@item.message.user.login}"}
          >@{@item.message.user.login}</button>
          <span class="message-meta-separator">·</span><time>{relative_time(@item.message.inserted_at)}</time>
        </div>
        <.message_body body={@item.message.body} />
      </div>
    </article>
    """
  end

  attr :form, :any, required: true
  attr :channel, :any, required: true
  attr :other_user, :any, default: nil

  defp composer(assigns) do
    ~H"""
    <div
      :if={@other_user && @other_user.disabled_at}
      id="direct-recipient-disabled"
      class="composer-disabled"
    >
      Этот пользователь отключён. История доступна только для чтения.
    </div>
    <.form
      :if={is_nil(@other_user) || is_nil(@other_user.disabled_at)}
      for={@form}
      id="message-form"
      phx-submit="send_message"
      class="composer"
    >
      <.input
        field={@form[:body]}
        id="message-body"
        type="textarea"
        class="chat-composer-input"
        rows="1"
        autocomplete="off"
        placeholder={
          if @other_user, do: "Написать @#{@other_user.login}", else: "Написать в ##{@channel.name}"
        }
        aria-label="Сообщение"
        phx-hook="MessageComposer"
      />
      <button id="send-message" type="submit" aria-label="Отправить сообщение"><.icon
        name="hero-arrow-up"
        class="size-4"
      /></button>
    </.form>
    """
  end

  attr :name, :string, required: true
  attr :user_id, :integer, default: nil
  attr :class, :any, required: true

  defp user_avatar(assigns) do
    assigns = assign(assigns, :variant, avatar_variant(assigns.user_id, assigns.name))

    ~H"""
    <div class={[@class, "avatar-variant-#{@variant}"]}>{initials(@name)}</div>
    """
  end

  defp avatar_variant(user_id, _name) when is_integer(user_id), do: rem(user_id, 4)

  defp avatar_variant(nil, name) do
    name |> String.trim() |> String.downcase() |> :erlang.phash2(4)
  end

  defp initials(name) do
    name
    |> String.split()
    |> Enum.map_join("", &String.first/1)
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp relative_time(datetime), do: Calendar.strftime(datetime, "%H:%M")

  attr :body, :string, required: true

  defp message_body(assigns) do
    ~H"""
    <p>
      <span
        :for={{kind, fragment} <- mention_fragments(@body)}
        class={kind == :mention && "message-mention"}
      >{fragment}</span>
    </p>
    """
  end

  defp mention_fragments(body) do
    ~r/(@[a-z0-9._-]+)/
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.map(fn fragment ->
      if Regex.match?(~r/^@[a-z0-9._-]+$/, fragment),
        do: {:mention, fragment},
        else: {:text, fragment}
    end)
  end
end
