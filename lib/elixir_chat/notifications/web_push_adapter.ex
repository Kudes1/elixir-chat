defmodule ElixirChat.Notifications.WebPushAdapter do
  @moduledoc false

  @callback send_notification(String.t(), String.t()) :: term()

  def send_notification(subscription_json, payload_json) do
    WebPushElixir.send_notification(subscription_json, payload_json)
  end
end
