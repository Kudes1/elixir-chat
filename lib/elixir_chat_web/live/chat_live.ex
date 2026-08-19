defmodule ElixirChatWeb.ChatLive do
  use ElixirChatWeb, :live_view

  alias ElixirChat.Accounts
  alias ElixirChat.Accounts.Scope
  alias ElixirChat.Chat
  alias ElixirChat.Chat.{Channel, DirectConversation, Message, Outbox}
  alias ElixirChat.Notifications
  alias ElixirChat.OnlineUsers
  alias ElixirChatWeb.Presence

  import ElixirChatWeb.ChatLive.Components
  alias ElixirChatWeb.ChatLive.{ConnectionState, MessageWindow}

  @presence_topic "presence:lobby"
  @message_page_size 50
  @default_time_zone "Etc/UTC"
  @catch_up_batch_size 200
  @catch_up_max_events 2_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      OnlineUsers.subscribe_count()
      Phoenix.PubSub.subscribe(ElixirChat.PubSub, OnlineUsers.updates_topic())
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

    channels = Chat.list_channels(socket.assigns.current_scope)

    conversation_ids =
      Enum.map(channels, & &1.id) ++ Enum.map(direct_conversations, & &1.direct.channel_id)

    missed_event_count = count_missed_events(socket, conversation_ids)
    catching_up? = missed_event_count > 0

    {:ok,
     socket
     |> assign(:page_title, "Orbit")
     |> assign(:time_zone, browser_time_zone(socket))
     |> assign(:missed_event_count, missed_event_count)
     |> assign(:catching_up?, catching_up?)
     |> assign(:connection_state, ConnectionState.initial_state(catching_up?))
     |> assign(:channels, channels)
     |> assign(:channel, nil)
     |> assign(:direct_conversation, nil)
     |> assign(:current_other_user, nil)
     |> assign(:direct_conversations, direct_conversations)
     |> assign(
       :unread_counts,
       Chat.list_unread_counts(socket.assigns.current_scope, conversation_ids)
     )
     |> assign(:muted_channel_ids, Notifications.muted_channel_ids(user.id))
     |> assign(:notifications_available?, Notifications.enabled?())
     |> assign(:vapid_public_key, Notifications.vapid_public_key())
     |> assign(:push_enabled?, Notifications.list_subscriptions(user.id) != [])
     |> assign(:subscribed_channel_id, nil)
     |> assign(:visitor_name, user.display_name)
     |> assign(:online_count, OnlineUsers.count())
     |> assign(:online_user_ids, OnlineUsers.online_ids())
     |> assign(:message_form, empty_message_form())
     |> assign(:editing_message_id, nil)
     |> assign(:direct_search_form, direct_search_form())
     |> assign(:direct_search_results, [])
     |> assign(:direct_search_open?, false)
     |> assign(:channel_create_open?, false)
     |> assign(:channel_catalog_open?, false)
     |> assign(:channel_settings_open?, false)
     |> assign(:channel_members_open?, false)
     |> assign(:channel_form, channel_form())
     |> assign(:available_channels, [])
     |> assign(:channel_memberships, [])
     |> assign(:invite_search_form, invite_search_form())
     |> assign(:invite_search_results, [])
     |> reset_message_assigns()
     |> stream(:messages, [])}
  end

  defp browser_time_zone(socket) do
    time_zone =
      if connected?(socket) do
        case get_connect_params(socket) do
          %{"time_zone" => time_zone} when is_binary(time_zone) -> time_zone
          _params -> @default_time_zone
        end
      else
        @default_time_zone
      end

    case DateTime.shift_zone(DateTime.utc_now(), time_zone) do
      {:ok, _datetime} -> time_zone
      {:error, _reason} -> @default_time_zone
    end
  end

  # Counts durable outbox events the browser hasn't seen yet, resuming from the
  # per-partition cursors it reported on connect. Purely observational for now
  # (assigns `:catching_up?`/`:missed_event_count`) — no UI/notification behavior
  # depends on this yet; it exists so later iterations (client state machine,
  # silent catch-up) have a correct foundation to build on.
  defp count_missed_events(socket, conversation_ids) do
    if connected?(socket) do
      conversation_ids
      |> catch_up_cursors(socket)
      |> tally_missed_events(0)
    else
      0
    end
  end

  defp catch_up_cursors(conversation_ids, socket) do
    client_cursors =
      case get_connect_params(socket) do
        %{"last_sequences" => map} when is_map(map) -> map
        _params -> %{}
      end

    Map.new(conversation_ids, fn channel_id ->
      partition_key = Outbox.partition_key(channel_id)
      {partition_key, parse_since_id(Map.get(client_cursors, partition_key))}
    end)
  end

  defp tally_missed_events(_cursors, total) when total >= @catch_up_max_events, do: total

  defp tally_missed_events(cursors, total) do
    case Outbox.list_events_since(cursors, limit: @catch_up_batch_size) do
      [] ->
        total

      events ->
        updated_cursors = advance_cursors(cursors, events)
        tally_missed_events(updated_cursors, total + length(events))
    end
  end

  defp advance_cursors(cursors, events) do
    Enum.reduce(events, cursors, fn event, acc ->
      Map.update(acc, event.partition_key, event.id, &max(&1, event.id))
    end)
  end

  defp parse_since_id(value) when is_integer(value) and value >= 0, do: value

  defp parse_since_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp parse_since_id(_value), do: 0

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
    attrs = %{
      body: Map.get(params, "body", ""),
      client_message_id: Map.get(params, "client_message_id")
    }

    case Chat.create_message(socket.assigns.current_scope, channel, attrs) do
      {:ok, message} ->
        socket = assign(socket, :message_form, empty_message_form())

        socket =
          if socket.assigns.at_latest? do
            MessageWindow.append_message(socket, message)
          else
            MessageWindow.load_latest_messages(socket)
          end

        {:noreply,
         push_event(socket, "message_sent", %{client_message_id: message.client_message_id})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :message_form, to_form(changeset, as: :message))}

      {:error, :recipient_disabled} ->
        {:noreply,
         socket
         |> refresh_active_direct()
         |> put_flash(:error, "Собеседник отключён. Отправка сообщений недоступна.")}

      {:error, :forbidden} ->
        {:noreply, recover_from_missing_conversation(socket, conversation_kind(socket))}

      {:error, :idempotency_conflict} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Не удалось повторно отправить сообщение: идентификатор уже использован."
         )}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("open_channel_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:channel_create_open?, true)
     |> assign(:channel_catalog_open?, false)
     |> assign(:channel_form, channel_form())}
  end

  def handle_event("close_channel_create", _params, socket),
    do: {:noreply, assign(socket, :channel_create_open?, false)}

  def handle_event("open_channel_catalog", _params, socket) do
    {:noreply,
     socket
     |> assign(:channel_catalog_open?, true)
     |> assign(:channel_create_open?, false)
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
         |> assign(:channel_create_open?, false)
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

  def handle_event("open_channel_members", _params, %{assigns: %{channel: channel}} = socket)
      when not is_nil(channel) do
    {:noreply,
     socket
     |> assign(:channel_members_open?, true)
     |> refresh_memberships()}
  end

  def handle_event("close_channel_members", _params, socket),
    do: {:noreply, assign(socket, :channel_members_open?, false)}

  def handle_event("update_channel", %{"channel" => params}, socket) do
    case Chat.update_channel(socket.assigns.current_scope, socket.assigns.channel, params) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel, channel)
         |> assign(:channel_settings_open?, false)
         |> assign(:channel_members_open?, false)
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

  def handle_event(
        "push_subscribe",
        %{"subscription" => %{"endpoint" => endpoint} = subscription},
        socket
      )
      when is_binary(endpoint) and endpoint != "" do
    keys = subscription["keys"] || %{}
    user = socket.assigns.current_scope.user

    case Notifications.subscribe(user, endpoint, keys["p256dh"], keys["auth"]) do
      {:ok, _subscription} ->
        {:reply, %{ok: true}, assign(socket, :push_enabled?, true)}

      {:error, _changeset} ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("push_subscribe", _params, socket),
    do: {:reply, %{ok: false}, socket}

  def handle_event("push_unsubscribe", %{"endpoint" => endpoint}, socket)
      when is_binary(endpoint) and endpoint != "" do
    user = socket.assigns.current_scope.user
    Notifications.unsubscribe(user, endpoint)

    {:reply, %{ok: true},
     assign(socket, :push_enabled?, Notifications.list_subscriptions(user.id) != [])}
  end

  def handle_event("push_unsubscribe", _params, socket), do: {:reply, %{ok: false}, socket}

  def handle_event("toggle_mute", %{"channel-id" => channel_id}, socket) do
    user = socket.assigns.current_scope.user

    case Integer.parse(to_string(channel_id)) do
      {id, ""} ->
        muted = MapSet.member?(socket.assigns.muted_channel_ids, id)
        Notifications.set_muted(user, id, not muted)

        muted_channel_ids =
          if muted,
            do: MapSet.delete(socket.assigns.muted_channel_ids, id),
            else: MapSet.put(socket.assigns.muted_channel_ids, id)

        {:noreply, assign(socket, :muted_channel_ids, muted_channel_ids)}

      _ ->
        {:noreply, socket}
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

  def handle_event("delete_message", %{"message-id" => message_id}, socket) do
    case Chat.delete_message(socket.assigns.current_scope, message_id) do
      {:ok, _message} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, channel_error(reason))}
    end
  end

  def handle_event("start_edit_message", %{"message-id" => message_id}, socket) do
    with {:ok, message} <- Chat.get_message(message_id),
         true <- Chat.can_edit_message?(socket.assigns.current_scope.user, message) do
      socket =
        socket
        |> assign(:editing_message_id, message.id)
        |> MessageWindow.update_message(message)

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_edit_message", %{"message-id" => message_id}, socket) do
    socket = assign(socket, :editing_message_id, nil)

    case Chat.get_message(message_id) do
      {:ok, message} -> {:noreply, MessageWindow.update_message(socket, message)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("save_edit_message", %{"message-id" => message_id, "body" => body}, socket) do
    case Chat.edit_message(socket.assigns.current_scope, message_id, %{body: body}) do
      {:ok, message} ->
        socket =
          socket
          |> assign(:editing_message_id, nil)
          |> MessageWindow.update_message(message)

        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Не удалось сохранить изменения.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:editing_message_id, nil)
         |> put_flash(:error, channel_error(reason))}
    end
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

  def handle_event(
        "mark_conversation_read",
        %{"channel_id" => channel_id, "message_id" => message_id},
        socket
      ) do
    if socket.assigns.channel && socket.assigns.at_latest? && socket.assigns.newest_message &&
         to_string(socket.assigns.channel.id) == to_string(channel_id) &&
         to_string(socket.assigns.newest_message.id) == to_string(message_id) do
      case Chat.mark_conversation_read(socket.assigns.current_scope, channel_id, message_id) do
        {:ok, count} ->
          {:reply, %{unread_count: count},
           put_unread_count(socket, socket.assigns.channel.id, count)}

        {:error, _reason} ->
          {:reply, %{error: "not_found"}, socket}
      end
    else
      {:reply, %{error: "stale_conversation"}, socket}
    end
  end

  # Mirrors the client's CATCHING_UP -> LIVE ("caught_up") transition back onto
  # `@connection_state`, which mount/3 otherwise only ever sets once and never
  # updates again for the life of this connected process. Without this, any
  # live event delivered via handle_info after a backlog catch-up would be
  # judged against a stale `:catching_up` and NotificationPolicy would treat it
  # as (correctly, but now permanently) silent catch-up traffic forever.
  def handle_event("client_caught_up", _params, socket) do
    case ConnectionState.transition(socket.assigns.connection_state, :caught_up) do
      {:ok, state} -> {:noreply, assign(socket, :connection_state, state)}
      {:error, :invalid_transition} -> {:noreply, socket}
    end
  end

  # Liveness probe (tasks/connect_concept.txt item 3): a no-op round trip the
  # client fires when it suspects the WebSocket is open but not actually
  # servicing requests (device wake, tab foregrounded, network change, etc.).
  # The reply itself carries no data — arriving at all, within the client's
  # own timeout, *is* the signal. See the ConnectionState hook /
  # connection_liveness.js for the client side of this contract.
  def handle_event("ping", _params, socket), do: {:reply, %{}, socket}

  @impl true
  def handle_info({:message_created, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, MessageWindow.receive_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:conversation_message_created, %Message{} = message, event}, socket) do
    socket =
      socket
      |> refresh_unread_count(message.channel_id)
      |> maybe_notify_channel_message(message, event)

    {:noreply, socket}
  end

  def handle_info({:conversation_message_deleted, %Message{} = message}, socket) do
    {:noreply, refresh_unread_count(socket, message.channel_id)}
  end

  def handle_info({:conversation_message_updated, %Message{}}, socket), do: {:noreply, socket}

  def handle_info({:message_deleted, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, MessageWindow.remove_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:direct_message_deleted, %DirectConversation{} = direct, %Message{} = message},
        socket
      ) do
    socket = refresh_unread_count(socket, message.channel_id)

    if socket.assigns.direct_conversation && socket.assigns.direct_conversation.id == direct.id do
      {:noreply, MessageWindow.remove_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_updated, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, MessageWindow.update_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:direct_message_updated, %DirectConversation{} = direct, %Message{} = message},
        socket
      ) do
    if socket.assigns.direct_conversation && socket.assigns.direct_conversation.id == direct.id do
      {:noreply, MessageWindow.update_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:direct_conversation_updated, %DirectConversation{} = direct}, socket) do
    {:noreply, upsert_direct(socket, direct, true)}
  end

  def handle_info(
        {:direct_message_created, %DirectConversation{} = direct, %Message{} = message, event},
        socket
      ) do
    active? =
      not is_nil(socket.assigns.direct_conversation) &&
        socket.assigns.direct_conversation.id == direct.id

    socket =
      socket
      |> upsert_direct(direct, true)
      |> refresh_unread_count(message.channel_id)
      |> maybe_notify_direct_message(direct, message, event, active?)

    if active? do
      {:noreply, MessageWindow.receive_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:channels_changed, channel_id}, socket) do
    socket =
      socket
      |> refresh_channels()
      |> refresh_all_unread_counts()
      |> refresh_available_channels_if_open()

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

  def handle_info({:conversation_read, channel_id, count}, socket) do
    {:noreply, put_unread_count(socket, channel_id, count)}
  end

  def handle_info({:catalog_changed, _channel_id}, socket) do
    {:noreply, refresh_available_channels_if_open(socket)}
  end

  def handle_info({:online_count, count}, socket) do
    {:noreply, assign(socket, :online_count, count)}
  end

  # Side-channel sequence advance (see ElixirChat.OutboxPublisher.broadcast_event_sequence/2).
  # Forwarded to the browser so it can keep its per-partition resume cursor current
  # while LIVE, without this being folded into the message/notification handlers above.
  def handle_info({:event_sequence, partition_key, seq}, socket) do
    {:noreply, push_event(socket, "event_seq", %{partition_key: partition_key, seq: seq})}
  end

  def handle_info({Presence, {:metas, key, metas}}, socket) do
    case Integer.parse(key) do
      {id, ""} ->
        online_user_ids =
          if metas == [],
            do: MapSet.delete(socket.assigns.online_user_ids, id),
            else: MapSet.put(socket.assigns.online_user_ids, id)

        {:noreply, assign(socket, :online_user_ids, online_user_ids)}

      :error ->
        {:noreply, socket}
    end
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

  # NotificationPolicy input: which conversation, whether the recipient is
  # currently looking at it (server-known), and message content for the
  # toast/sound decision made client-side in assets/js/notification_policy.js.
  # Never sent for the author's own message, while muted (mirrors the existing
  # push-notification mute filtering in ElixirChat.Notifications), or before
  # `@connection_state` is `:live` — this is what makes catch-up silent by
  # construction rather than by a per-event check on the client.
  #
  # `priority` is resolved here rather than left for the client to infer from
  # `type`, since only the server knows (from the durable Notification rows —
  # `Notifications.mentioned?/2`) whether this particular recipient was
  # actually `@mention`-ed: a plain channel message is "low" for everyone,
  # but a channel message that mentions this recipient is just as urgent as
  # a DM ("high"), and no two recipients of the same message necessarily
  # agree on which it is.
  defp maybe_notify_channel_message(socket, message, event) do
    user = socket.assigns.current_scope.user

    if notifiable?(socket, user, message) do
      priority = if Notifications.mentioned?(message.id, user.id), do: "high", else: "low"

      push_notify(socket, %{
        event_id: event.event_id,
        type: "channel",
        priority: priority,
        active:
          not is_nil(socket.assigns.channel) && socket.assigns.channel.id == message.channel_id,
        title: event.title,
        body: event.body,
        url: event.url,
        channel_id: message.channel_id
      })
    else
      socket
    end
  end

  defp maybe_notify_direct_message(socket, _direct, message, event, active?) do
    user = socket.assigns.current_scope.user

    if notifiable?(socket, user, message) do
      push_notify(socket, %{
        event_id: event.event_id,
        type: "direct",
        priority: "high",
        active: active?,
        title: event.title,
        body: event.body,
        url: event.url,
        channel_id: message.channel_id
      })
    else
      socket
    end
  end

  defp notifiable?(socket, user, message) do
    message.user_id != user.id and socket.assigns.connection_state == :live and
      not Notifications.muted?(user.id, message.channel_id)
  end

  defp push_notify(socket, attrs) do
    push_event(socket, "notify", %{
      event_id: attrs.event_id,
      type: attrs.type,
      priority: attrs.priority,
      active: attrs.active,
      title: attrs.title,
      body: attrs.body,
      url: attrs.url,
      # Conversation grouping key for the client's sound-cooldown gate
      # (assets/js/sound_cooldown.js) — a burst of several notifies for the
      # same channel/direct conversation should collapse to one sound, not
      # silence unrelated conversations too.
      channel_id: attrs.channel_id
    })
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
    |> assign(:channel_members_open?, false)
    |> reset_message_assigns()
    |> stream(:messages, [], reset: true)
  end

  defp reset_message_assigns(socket) do
    socket
    |> assign(:oldest_message, nil)
    |> assign(:newest_message, nil)
    |> assign(:message_count, 0)
    |> assign(:loaded_message_ids, MapSet.new())
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

    socket =
      socket
      |> assign(:direct_conversations, direct_conversations)
      |> ensure_unread_count(direct.channel_id)

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

  defp refresh_all_unread_counts(socket) do
    ids =
      Enum.map(socket.assigns.channels, & &1.id) ++
        Enum.map(socket.assigns.direct_conversations, & &1.direct.channel_id)

    assign(socket, :unread_counts, Chat.list_unread_counts(socket.assigns.current_scope, ids))
  end

  defp refresh_unread_count(socket, channel_id) do
    count =
      socket.assigns.current_scope
      |> Chat.list_unread_counts([channel_id])
      |> Map.get(channel_id, 0)

    put_unread_count(socket, channel_id, count)
  end

  defp ensure_unread_count(socket, channel_id) do
    if Map.has_key?(socket.assigns.unread_counts, channel_id),
      do: socket,
      else: refresh_unread_count(socket, channel_id)
  end

  defp put_unread_count(socket, channel_id, count) do
    assign(socket, :unread_counts, Map.put(socket.assigns.unread_counts, channel_id, count))
  end

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

  defp refresh_memberships_if_open(%{assigns: %{channel_members_open?: true}} = socket),
    do: refresh_memberships(socket)

  defp refresh_memberships_if_open(socket), do: socket

  defp channel_error(:protected_channel), do: "Основной канал защищён от этого действия."
  defp channel_error(:owner_must_transfer), do: "Сначала передайте владение другому участнику."
  defp channel_error(:forbidden), do: "Недостаточно прав для этого действия."
  defp channel_error(:not_member), do: "Пользователь не является участником канала."
  defp channel_error(:invalid_target), do: "Нельзя передать владение этому пользователю."
  defp channel_error(:not_found), do: "Сообщение не найдено."
  defp channel_error(_reason), do: "Не удалось изменить канал."

  def empty_message_form,
    do: to_form(%{"body" => "", "client_message_id" => Ecto.UUID.generate()}, as: :message)

  defp direct_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :direct_search)
  defp invite_search_form(query \\ ""), do: to_form(%{"query" => query}, as: :invite_search)

  defp channel_form do
    %Channel{kind: :public, purpose: :group}
    |> Chat.change_channel()
    |> to_form()
  end
end
