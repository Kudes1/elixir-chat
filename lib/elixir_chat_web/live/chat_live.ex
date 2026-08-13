defmodule ElixirChatWeb.ChatLive do
  use ElixirChatWeb, :live_view

  alias ElixirChat.Chat
  alias ElixirChat.Chat.Message
  alias ElixirChatWeb.Presence

  @presence_topic "presence:lobby"

  @impl true
  def mount(_params, session, socket) do
    guest_id = Map.fetch!(session, "guest_id")
    visitor_name = Map.fetch!(session, "visitor_name")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElixirChat.PubSub, @presence_topic)

      {:ok, _ref} =
        Presence.track(self(), @presence_topic, guest_id, %{
          name: visitor_name,
          online_at: System.system_time(:second)
        })
    end

    {:ok,
     socket
     |> assign(:page_title, "Orbit")
     |> assign(:current_scope, nil)
     |> assign(:channels, Chat.list_channels())
     |> assign(:channel, nil)
     |> assign(:subscribed_channel_id, nil)
     |> assign(:visitor_name, visitor_name)
     |> assign(:online_count, presence_count())
     |> assign(:message_form, empty_message_form())
     |> assign(:oldest_message, nil)
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
    attrs = %{body: Map.get(params, "body", ""), author_name: socket.assigns.visitor_name}

    case Chat.create_message(channel, attrs) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:message_form, empty_message_form())
         |> stream_insert(:messages, message)
         |> push_event("message_sent", %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, :message_form, to_form(changeset, as: :message))}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("load_older_messages", _params, socket) do
    case socket.assigns do
      %{channel: channel, has_older_messages?: true, oldest_message: %Message{} = oldest} ->
        {messages, has_older_messages?} = Chat.list_messages_before(channel.id, oldest)

        {:noreply,
         socket
         |> assign(:oldest_message, List.first(messages) || oldest)
         |> assign(:has_older_messages?, has_older_messages?)
         |> stream(:messages, Enum.reverse(messages), at: 0)
         |> push_event("older_messages_loaded", %{})}

      _ ->
        {:noreply, push_event(socket, "older_messages_loaded", %{})}
    end
  end

  @impl true
  def handle_info({:message_created, %Message{} = message}, socket) do
    if socket.assigns.channel && message.channel_id == socket.assigns.channel.id do
      {:noreply, stream_insert(socket, :messages, message)}
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
    |> assign(:has_older_messages?, has_older_messages?)
    |> assign(:message_form, empty_message_form())
    |> stream(:messages, messages, reset: true)
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
    |> assign(:has_older_messages?, false)
    |> stream(:messages, [], reset: true)
  end

  defp empty_message_form, do: to_form(%{"body" => ""}, as: :message)
  defp presence_count, do: Presence.list(@presence_topic) |> map_size()

  defp initials(name) do
    name
    |> String.split()
    |> Enum.map_join("", &String.first/1)
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp relative_time(datetime), do: Calendar.strftime(datetime, "%H:%M")
end
