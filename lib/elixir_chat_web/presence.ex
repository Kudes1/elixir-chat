defmodule ElixirChatWeb.Presence do
  @moduledoc """
  Tracks connected visitors. The topic-based design also works across nodes once
  the application's PubSub is configured for a cluster.
  """

  use Phoenix.Presence,
    otp_app: :elixir_chat,
    pubsub_server: ElixirChat.PubSub
end
