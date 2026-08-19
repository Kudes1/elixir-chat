defmodule ElixirChat.Chat.Outbox do
  @moduledoc false

  import Ecto.Query

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.{Channel, DirectConversation, Message, OutboxEvent}
  alias ElixirChat.Repo

  @default_replay_limit 500

  @doc """
  Lists events for a single partition strictly after `since_id`, oldest first.

  Used to replay the events a client missed for one channel/direct conversation.
  """
  def list_since(partition_key, since_id, limit \\ @default_replay_limit) do
    OutboxEvent
    |> where([e], e.partition_key == ^partition_key and e.id > ^since_id)
    |> order_by([e], asc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists events across several partitions, each resumed from its own cursor.

  `cursors` is a map of `partition_key => since_id` (events with `id > since_id` for
  that partition are returned). Events are returned oldest-first across all
  partitions combined, capped at `:limit` (default #{@default_replay_limit}) so a
  large backlog is drained in batches rather than in one unbounded query — callers
  needing more than `limit` events should re-invoke with cursors advanced to the
  highest `id` seen per partition in the previous batch.
  """
  def list_events_since(cursors, opts \\ [])

  def list_events_since(cursors, _opts) when map_size(cursors) == 0, do: []

  def list_events_since(cursors, opts) do
    limit = Keyword.get(opts, :limit, @default_replay_limit)

    condition =
      Enum.reduce(cursors, dynamic(false), fn {partition_key, since_id}, acc ->
        dynamic([e], ^acc or (e.partition_key == ^partition_key and e.id > ^since_id))
      end)

    OutboxEvent
    |> where(^condition)
    |> order_by([e], asc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Deletes one batch (default #{@default_replay_limit}) of already-published
  events with `published_at` older than `cutoff`. Never touches unpublished
  events regardless of age — those are still being retried by
  `ElixirChat.Workers.PublishOutboxEvent` (effectively forever) and are not
  eligible for cleanup just because they're old.

  Returns the number of rows deleted, so a caller (an Oban cleanup worker)
  can loop via `ElixirChat.Workers.BatchDelete.run/1` until a batch comes
  back empty instead of deleting an unbounded backlog in one statement.
  """
  def delete_published_before(cutoff, batch_size \\ @default_replay_limit) do
    {count, _} =
      Repo.delete_all(
        from e in OutboxEvent,
          where:
            e.id in subquery(
              from e2 in OutboxEvent,
                where: not is_nil(e2.published_at) and e2.published_at < ^cutoff,
                select: e2.id,
                limit: ^batch_size
            )
      )

    count
  end

  def partition_key(channel_id), do: "channel:#{channel_id}"

  def event_changeset(event_type, %Message{} = message, direct \\ nil) do
    OutboxEvent.changeset(%OutboxEvent{}, %{
      event_id: Ecto.UUID.generate(),
      event_type: Atom.to_string(event_type),
      partition_key: partition_key(message.channel_id),
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
