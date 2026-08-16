defmodule ElixirChat.Chat.Outbox do
  @moduledoc false

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.{Channel, DirectConversation, Message, OutboxEvent}

  def event_changeset(event_type, %Message{} = message, direct \\ nil) do
    now = DateTime.utc_now()

    OutboxEvent.changeset(%OutboxEvent{}, %{
      event_id: Ecto.UUID.generate(),
      event_type: Atom.to_string(event_type),
      partition_key: "channel:#{message.channel_id}",
      available_at: now,
      payload: payload(event_type, message, direct)
    })
  end

  def decode(%OutboxEvent{event_type: event_type, payload: payload}) do
    message = decode_message(payload["message"])
    event_type = decode_event_type(event_type)

    case payload["routing"] do
      %{"kind" => "group"} ->
        {event_type, message}

      %{"kind" => "direct", "direct" => direct} ->
        {event_type, decode_direct(direct), message}
    end
  end

  defp payload(event_type, message, nil) do
    %{
      "version" => 1,
      "routing" => %{"kind" => "group", "channel_id" => message.channel_id},
      "event_type" => Atom.to_string(event_type),
      "message" => encode_message(message)
    }
  end

  defp payload(event_type, message, %DirectConversation{} = direct) do
    %{
      "version" => 1,
      "routing" => %{
        "kind" => "direct",
        "channel_id" => message.channel_id,
        "recipient_user_ids" => [direct.first_user_id, direct.second_user_id],
        "direct" => encode_direct(direct)
      },
      "event_type" => Atom.to_string(event_type),
      "message" => encode_message(message)
    }
  end

  defp encode_message(message) do
    %{
      "id" => message.id,
      "client_message_id" => message.client_message_id,
      "author_name" => message.author_name,
      "body" => message.body,
      "channel_id" => message.channel_id,
      "user_id" => message.user_id,
      "inserted_at" => encode_datetime(message.inserted_at),
      "updated_at" => encode_datetime(message.updated_at),
      "channel" => encode_channel(message.channel),
      "user" => encode_user(message.user)
    }
  end

  defp encode_direct(direct) do
    %{
      "id" => direct.id,
      "channel_id" => direct.channel_id,
      "first_user_id" => direct.first_user_id,
      "second_user_id" => direct.second_user_id,
      "last_activity_at" => encode_datetime(direct.last_activity_at),
      "inserted_at" => encode_datetime(direct.inserted_at),
      "updated_at" => encode_datetime(direct.updated_at),
      "channel" => encode_channel(direct.channel),
      "first_user" => encode_user(direct.first_user),
      "second_user" => encode_user(direct.second_user)
    }
  end

  defp encode_channel(channel) do
    %{
      "id" => channel.id,
      "public_id" => channel.public_id,
      "name" => channel.name,
      "description" => channel.description,
      "kind" => Atom.to_string(channel.kind),
      "purpose" => Atom.to_string(channel.purpose),
      "owner_id" => channel.owner_id,
      "is_general" => channel.is_general,
      "archived_at" => encode_datetime(channel.archived_at),
      "inserted_at" => encode_datetime(channel.inserted_at),
      "updated_at" => encode_datetime(channel.updated_at)
    }
  end

  defp encode_user(user) do
    %{
      "id" => user.id,
      "login" => user.login,
      "display_name" => user.display_name,
      "role" => Atom.to_string(user.role),
      "disabled_at" => encode_datetime(user.disabled_at),
      "inserted_at" => encode_datetime(user.inserted_at),
      "updated_at" => encode_datetime(user.updated_at)
    }
  end

  defp decode_message(value) do
    struct(Message,
      id: value["id"],
      client_message_id: value["client_message_id"],
      author_name: value["author_name"],
      body: value["body"],
      channel_id: value["channel_id"],
      user_id: value["user_id"],
      inserted_at: decode_datetime(value["inserted_at"]),
      updated_at: decode_datetime(value["updated_at"]),
      channel: decode_channel(value["channel"]),
      user: decode_user(value["user"])
    )
  end

  defp decode_direct(value) do
    struct(DirectConversation,
      id: value["id"],
      channel_id: value["channel_id"],
      first_user_id: value["first_user_id"],
      second_user_id: value["second_user_id"],
      last_activity_at: decode_datetime(value["last_activity_at"]),
      inserted_at: decode_datetime(value["inserted_at"]),
      updated_at: decode_datetime(value["updated_at"]),
      channel: decode_channel(value["channel"]),
      first_user: decode_user(value["first_user"]),
      second_user: decode_user(value["second_user"])
    )
  end

  defp decode_channel(value) do
    struct(Channel,
      id: value["id"],
      public_id: value["public_id"],
      name: value["name"],
      description: value["description"],
      kind: String.to_existing_atom(value["kind"]),
      purpose: String.to_existing_atom(value["purpose"]),
      owner_id: value["owner_id"],
      is_general: value["is_general"],
      archived_at: decode_datetime(value["archived_at"]),
      inserted_at: decode_datetime(value["inserted_at"]),
      updated_at: decode_datetime(value["updated_at"])
    )
  end

  defp decode_user(value) do
    struct(User,
      id: value["id"],
      login: value["login"],
      display_name: value["display_name"],
      role: String.to_existing_atom(value["role"]),
      disabled_at: decode_datetime(value["disabled_at"]),
      inserted_at: decode_datetime(value["inserted_at"]),
      updated_at: decode_datetime(value["updated_at"])
    )
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(value), do: DateTime.to_iso8601(value)
  defp decode_datetime(nil), do: nil
  defp decode_datetime(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp decode_event_type("message_created"), do: :message_created
  defp decode_event_type("message_updated"), do: :message_updated
  defp decode_event_type("message_deleted"), do: :message_deleted
  defp decode_event_type("direct_message_created"), do: :direct_message_created
  defp decode_event_type("direct_message_updated"), do: :direct_message_updated
  defp decode_event_type("direct_message_deleted"), do: :direct_message_deleted
end
