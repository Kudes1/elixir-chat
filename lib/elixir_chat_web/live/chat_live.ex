defmodule ElixirChatWeb.ChatLive do
  use ElixirChatWeb, :live_view

  alias ElixirChat.Chat
  alias ElixirChat.Chat.Message
  alias ElixirChatWeb.Presence

  @presence_topic "presence:lobby"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElixirChat.PubSub, @presence_topic)

      {:ok, _ref} =
        Presence.track(self(), @presence_topic, to_string(user.id), %{
          name: user.display_name,
          online_at: System.system_time(:second)
        })
    end

    {:ok,
     socket
     |> assign(:page_title, "Orbit")
     |> assign(:channels, Chat.list_channels())
     |> assign(:channel, nil)
     |> assign(:subscribed_channel_id, nil)
     |> assign(:visitor_name, user.display_name)
     |> assign(:online_count, presence_count())
     |> assign(:message_form, empty_message_form())
     |> assign(:oldest_message, nil)
     |> assign(:newest_message, nil)
     |> assign(:has_older_messages?, false)
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Chat.get_channel(id) do
      {:ok, channel} -> {:noreply, load_channel(socket, channel)}
      {:error, :not_found} -> {:noreply, recover_from_missing_channel(socket)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, clear_channel(socket)}
  end

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
        {:noreply,
         socket
         |> assign(:message_form, empty_message_form())
         |> append_message(message)
         |> push_event("message_sent", %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, :message_form, to_form(changeset, as: :message))}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("insert_mention", %{"login" => login}, socket) do
    {:noreply, push_event(socket, "insert_mention", %{mention: "@#{login}"})}
  end

  @impl true
  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns do
      %{channel: channel, has_older_messages?: true, oldest_message: %Message{} = oldest} ->
        {messages, has_older_messages?} = Chat.list_messages_before(channel.id, oldest)

        {:noreply,
         socket
         |> assign(:oldest_message, List.first(messages) || oldest)
         |> assign(:has_older_messages?, has_older_messages?)
         |> prepend_messages(messages, oldest)
         |> push_event("older_messages_loaded", %{})}

      _ ->
        {:noreply, push_event(socket, "older_messages_loaded", %{})}
    end
  end

  @impl true
  def handle_info({:message_created, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, append_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online_count, presence_count())}
  end

  defp load_channel(socket, channel) do
    old_channel_id = socket.assigns.subscribed_channel_id

    if connected?(socket) && old_channel_id != channel.id do
      Chat.subscribe(channel.id)
    end

    {messages, has_older_messages?} = Chat.list_recent_messages(channel.id)

    if connected?(socket) && old_channel_id && old_channel_id != channel.id do
      Phoenix.PubSub.unsubscribe(ElixirChat.PubSub, Chat.topic(old_channel_id))
    end

    socket
    |> assign(:channel, channel)
    |> assign(:subscribed_channel_id, channel.id)
    |> assign(:oldest_message, List.first(messages))
    |> assign(:newest_message, List.last(messages))
    |> assign(:has_older_messages?, has_older_messages?)
    |> assign(:message_form, empty_message_form())
    |> stream(:messages, message_items(messages), reset: true)
    |> push_event("scroll_to_latest", %{})
  end

  defp recover_from_missing_channel(socket) do
    case Chat.get_default_channel() do
      {:ok, channel} ->
        socket
        |> put_flash(:error, "Канал не найден. Открыт основной канал.")
        |> push_patch(to: ~p"/channels/#{channel.id}")

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Пока нет доступных каналов.")
        |> push_patch(to: ~p"/channels")
    end
  end

  defp clear_channel(socket) do
    if connected?(socket) && socket.assigns.subscribed_channel_id do
      Phoenix.PubSub.unsubscribe(
        ElixirChat.PubSub,
        Chat.topic(socket.assigns.subscribed_channel_id)
      )
    end

    socket
    |> assign(:channel, nil)
    |> assign(:subscribed_channel_id, nil)
    |> assign(:oldest_message, nil)
    |> assign(:newest_message, nil)
    |> assign(:has_older_messages?, false)
    |> stream(:messages, [], reset: true)
  end

  defp append_message(%{assigns: %{newest_message: %Message{id: id}}} = socket, %Message{id: id}),
    do: socket

  defp append_message(socket, message) do
    previous_message = socket.assigns.newest_message

    socket
    |> assign(:newest_message, message)
    |> stream_insert(:messages, message_item(message, previous_message))
  end

  defp prepend_messages(socket, [], _oldest), do: socket

  defp prepend_messages(socket, messages, oldest) do
    socket
    |> stream(:messages, messages |> message_items() |> Enum.reverse(), at: 0)
    |> stream_insert(:messages, message_item(oldest, List.last(messages)))
  end

  defp message_items(messages) do
    messages
    |> Enum.map_reduce(nil, fn message, previous_message ->
      {message_item(message, previous_message), message}
    end)
    |> elem(0)
  end

  defp message_item(message, previous_message) do
    %{
      id: message.id,
      message: message,
      continuation?: same_author?(message, previous_message)
    }
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

  defp empty_message_form, do: to_form(%{"body" => ""}, as: :message)
  defp presence_count, do: Presence.list(@presence_topic) |> map_size()

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
    name
    |> String.trim()
    |> String.downcase()
    |> :erlang.phash2(4)
  end

  defp initials(name) do
    name
    |> String.split()
    |> Enum.map_join("", &String.first/1)
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp relative_time(datetime), do: Calendar.strftime(datetime, "%H:%M")

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
