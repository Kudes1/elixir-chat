defmodule ElixirChat.OutboxPublisher do
  @moduledoc false

  alias ElixirChat.Chat.Outbox

  def publish(event) do
    case Outbox.decode(event) do
      {event_type, message} ->
        Phoenix.PubSub.broadcast(
          ElixirChat.PubSub,
          ElixirChat.Chat.topic(message.channel_id),
          {event_type, message}
        )

        notification_type = conversation_notification_type(event_type)
        recipient_ids = ElixirChat.Chat.conversation_user_ids(message.channel_id)

        Enum.each(recipient_ids, fn user_id ->
          Phoenix.PubSub.broadcast(
            ElixirChat.PubSub,
            ElixirChat.Chat.user_topic(user_id),
            {notification_type, message}
          )
        end)

        broadcast_event_sequence(recipient_ids, event)

        if event_type == :message_created do
          ElixirChat.Notifications.enqueue(:channel, message)
        end

        :ok

      {event_type, direct, message} ->
        tuple = {event_type, direct, message}
        recipient_ids = [direct.first_user_id, direct.second_user_id]

        Phoenix.PubSub.broadcast(
          ElixirChat.PubSub,
          ElixirChat.Chat.user_topic(direct.first_user_id),
          tuple
        )

        Phoenix.PubSub.broadcast(
          ElixirChat.PubSub,
          ElixirChat.Chat.user_topic(direct.second_user_id),
          tuple
        )

        broadcast_event_sequence(recipient_ids, event)

        if event_type == :direct_message_created do
          ElixirChat.Notifications.enqueue(:direct, message, direct)
        end

        :ok
    end
  end

  # Additive, side-channel notice of the durable sequence (outbox event id) each
  # recipient has now caught up to for this partition — lets the browser advance
  # its resume cursor during LIVE operation without touching the existing
  # message/notification broadcast payloads above.
  defp broadcast_event_sequence(recipient_ids, %{partition_key: partition_key, id: seq}) do
    Enum.each(recipient_ids, fn user_id ->
      Phoenix.PubSub.broadcast(
        ElixirChat.PubSub,
        ElixirChat.Chat.user_topic(user_id),
        {:event_sequence, partition_key, seq}
      )
    end)
  end

  defp conversation_notification_type(:message_created), do: :conversation_message_created
  defp conversation_notification_type(:message_updated), do: :conversation_message_updated
  defp conversation_notification_type(:message_deleted), do: :conversation_message_deleted
end
