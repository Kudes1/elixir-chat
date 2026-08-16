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

        Enum.each(ElixirChat.Chat.conversation_user_ids(message.channel_id), fn user_id ->
          Phoenix.PubSub.broadcast(
            ElixirChat.PubSub,
            ElixirChat.Chat.user_topic(user_id),
            {notification_type, message}
          )
        end)

        :ok

      {event_type, direct, message} ->
        tuple = {event_type, direct, message}

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

        :ok
    end
  end

  defp conversation_notification_type(:message_created), do: :conversation_message_created
  defp conversation_notification_type(:message_updated), do: :conversation_message_updated
  defp conversation_notification_type(:message_deleted), do: :conversation_message_deleted
end
