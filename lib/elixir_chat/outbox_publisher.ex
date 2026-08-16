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
end
