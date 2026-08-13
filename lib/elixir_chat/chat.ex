defmodule ElixirChat.Chat do
  @moduledoc "The chat domain: durable channels/messages and real-time broadcasts."

  import Ecto.Query, warn: false

  alias ElixirChat.Repo
  alias ElixirChat.Chat.{Channel, Message}

  @pubsub ElixirChat.PubSub
  @message_page_size 50

  def list_channels do
    Channel
    |> where([channel], channel.kind == :public)
    |> order_by([channel], asc: channel.name)
    |> Repo.all()
  end

  def get_channel(id) do
    case parse_id(id) do
      {:ok, channel_id} -> get_channel_by_id(channel_id)
      :error -> {:error, :not_found}
    end
  end

  def get_default_channel do
    query = from channel in Channel, where: channel.kind == :public

    channel =
      Repo.one(from channel in query, where: channel.name == "general", limit: 1) ||
        Repo.one(from channel in query, order_by: [asc: channel.name], limit: 1)

    if channel, do: {:ok, channel}, else: {:error, :not_found}
  end

  def list_recent_messages(channel_id, page_size \\ @message_page_size) do
    channel_id
    |> messages_query()
    |> message_page(page_size)
  end

  def list_messages(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> preload([:channel, :user])
    |> Repo.all()
  end

  def list_messages_before(channel_id, %Message{} = cursor, page_size \\ @message_page_size) do
    channel_id
    |> messages_query()
    |> where(
      [message],
      message.inserted_at < ^cursor.inserted_at or
        (message.inserted_at == ^cursor.inserted_at and message.id < ^cursor.id)
    )
    |> message_page(page_size)
  end

  def subscribe(channel_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(channel_id))

  def create_message(%ElixirChat.Accounts.Scope{user: user}, %Channel{} = channel, attrs) do
    result =
      %Message{channel_id: channel.id, user_id: user.id, author_name: user.display_name}
      |> Message.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, message} ->
        message = Repo.preload(message, [:channel, :user])
        Phoenix.PubSub.broadcast(@pubsub, topic(channel.id), {:message_created, message})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def topic(channel_id), do: "chat:#{channel_id}"

  defp get_channel_by_id(id) do
    query = from channel in Channel, where: channel.kind == :public and channel.id == ^id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_id(_id), do: :error

  defp messages_query(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> preload([:channel, :user])
  end

  defp message_page(query, page_size) do
    messages =
      query
      |> limit(^(page_size + 1))
      |> Repo.all()

    {messages |> Enum.take(page_size) |> Enum.reverse(), length(messages) > page_size}
  end
end
