defmodule ElixirChat.Notifications.Event do
  @moduledoc """
  The single notification payload shape shared by the WebSocket and Web Push
  transports, keyed by `event_id` (the originating `ElixirChat.Chat.OutboxEvent`'s
  UUID) so a client-side Service Worker can deduplicate a message delivered
  through both transports into exactly one system notification.
  """

  @derive Jason.Encoder
  @enforce_keys [:event_id, :type, :title, :body, :url]
  defstruct [:event_id, :type, :title, :body, :url]
end
