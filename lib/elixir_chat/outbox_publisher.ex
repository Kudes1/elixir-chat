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

        if event_type == :message_created do
          notification_event =
            ElixirChat.Notifications.build_channel_event(event.event_id, message)

          Enum.each(recipient_ids, fn user_id ->
            Phoenix.PubSub.broadcast(
              ElixirChat.PubSub,
              ElixirChat.Chat.user_topic(user_id),
              {notification_type, message, notification_event}
            )
          end)

          ElixirChat.Notifications.enqueue(:channel, message, notification_event)
        else
          Enum.each(recipient_ids, fn user_id ->
            Phoenix.PubSub.broadcast(
              ElixirChat.PubSub,
              ElixirChat.Chat.user_topic(user_id),
              {notification_type, message}
            )
          end)
        end

        broadcast_event_sequence(recipient_ids, event)

        :ok

      {event_type, direct, message} ->
        recipient_ids = [direct.first_user_id, direct.second_user_id]

        tuple =
          if event_type == :direct_message_created do
            notification_event =
              ElixirChat.Notifications.build_direct_event(event.event_id, message, direct)

            ElixirChat.Notifications.enqueue(:direct, message, direct, notification_event)

            {event_type, direct, message, notification_event}
          else
            {event_type, direct, message}
          end

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
