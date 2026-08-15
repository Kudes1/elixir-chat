defmodule ElixirChatWeb.ChatLive.MessageWindow do
  alias ElixirChat.Chat
  alias ElixirChat.Chat.Message
  alias ElixirChatWeb.ChatLive

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [
      connected?: 1,
      stream: 4,
      stream_insert: 3,
      stream_insert: 4,
      stream_delete: 3,
      push_event: 3
    ]

  @message_page_size 50
  @message_window_size 150

  def load_conversation(socket, channel, direct) do
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
      ChatLive.conversation_title(channel, direct, socket.assigns.current_scope.user.id)
    )
    |> assign(:channel, channel)
    |> assign(:direct_conversation, direct)
    |> assign(
      :current_other_user,
      ChatLive.other_user(direct, socket.assigns.current_scope.user.id)
    )
    |> assign(:subscribed_channel_id, new_channel_id)
    |> assign(:message_form, ChatLive.empty_message_form())
    |> load_latest_messages()
  end

  def load_latest_messages(%{assigns: %{channel: nil}} = socket), do: socket

  def load_latest_messages(socket) do
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

  def receive_message(%{assigns: %{at_latest?: true}} = socket, message),
    do: append_message(socket, message)

  def receive_message(socket, _message), do: assign(socket, :pending_new_messages?, true)

  def append_message(%{assigns: %{newest_message: %Message{id: id}}} = socket, %Message{id: id}),
    do: socket

  def append_message(socket, message) do
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

  def remove_message(socket, %Message{} = message) do
    in_window? = within_loaded_window?(socket, message)
    original_newest = socket.assigns.newest_message

    {next, previous} =
      if in_window? do
        {next_message(socket, message), previous_message(socket, message)}
      else
        {nil, nil}
      end

    socket
    |> maybe_decrement_message_count(in_window?)
    |> replace_oldest_if_removed(message, next)
    |> replace_newest_if_removed(message, previous)
    |> stream_delete(:messages, %{id: message.id})
    |> regroup_next(next, previous)
    |> reconcile_pending_after_removal(message, original_newest)
  end

  defp maybe_decrement_message_count(socket, true),
    do: assign(socket, :message_count, max(socket.assigns.message_count - 1, 0))

  defp maybe_decrement_message_count(socket, false), do: socket

  defp reconcile_pending_after_removal(socket, %Message{id: id}, %Message{id: id}), do: socket

  defp reconcile_pending_after_removal(socket, message, %Message{} = original_newest) do
    if cursor_lte?(original_newest, message) do
      {after_newest, _has_more?} =
        fetch_messages_after(socket, socket.assigns.channel.id, original_newest, 1)

      assign(socket, :pending_new_messages?, after_newest != [])
    else
      socket
    end
  end

  defp reconcile_pending_after_removal(socket, _message, nil), do: socket

  defp regroup_next(socket, nil, _previous), do: socket

  defp regroup_next(socket, next, previous),
    do: stream_insert(socket, :messages, message_item(next, previous))

  defp replace_oldest_if_removed(socket, %Message{id: id}, replacement) do
    case socket.assigns.oldest_message do
      %Message{id: ^id} -> assign(socket, :oldest_message, replacement)
      _ -> socket
    end
  end

  defp replace_newest_if_removed(socket, %Message{id: id}, replacement) do
    case socket.assigns.newest_message do
      %Message{id: ^id} -> assign(socket, :newest_message, replacement)
      _ -> socket
    end
  end

  defp within_loaded_window?(socket, %Message{} = candidate) do
    case {socket.assigns.oldest_message, socket.assigns.newest_message} do
      {%Message{} = oldest, %Message{} = newest} ->
        cursor_lte?(oldest, candidate) and cursor_lte?(candidate, newest)

      _ ->
        false
    end
  end

  defp cursor_lte?(%Message{inserted_at: at_a, id: id_a}, %Message{inserted_at: at_b, id: id_b}) do
    case DateTime.compare(at_a, at_b) do
      :lt -> true
      :gt -> false
      :eq -> id_a <= id_b
    end
  end

  defp next_message(socket, message) do
    case fetch_messages_after(socket, socket.assigns.channel.id, message, 1) do
      {[next], _has_more?} -> next
      {[], _has_more?} -> nil
    end
  end

  defp previous_message(socket, message) do
    case fetch_messages_before(socket, socket.assigns.channel.id, message, 1) do
      {[previous], _has_more?} -> previous
      {[], _has_more?} -> nil
    end
  end

  def prepend_messages(socket, [], _oldest, has_older_messages?) do
    socket
    |> assign(:has_older_messages?, has_older_messages?)
    |> push_event("older_messages_loaded", %{})
  end

  def prepend_messages(socket, messages, oldest, has_older_messages?) do
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

  def append_newer_messages(socket, [], has_newer_messages?) do
    socket
    |> assign(:has_newer_messages?, has_newer_messages?)
    |> assign(:at_latest?, !has_newer_messages?)
    |> assign(:pending_new_messages?, has_newer_messages? && socket.assigns.pending_new_messages?)
    |> push_event("newer_messages_loaded", %{})
  end

  def append_newer_messages(socket, messages, has_newer_messages?) do
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

  def message_items(messages, previous_message \\ nil) do
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

  defp fetch_recent_messages(socket, id, size) do
    {:ok, page} = Chat.list_recent_messages(socket.assigns.current_scope, id, size)
    page
  end

  def fetch_messages_before(socket, id, cursor, size) do
    {:ok, page} = Chat.list_messages_before(socket.assigns.current_scope, id, cursor, size)
    page
  end

  def fetch_messages_after(socket, id, cursor, size) do
    {:ok, page} = Chat.list_messages_after(socket.assigns.current_scope, id, cursor, size)
    page
  end
end
