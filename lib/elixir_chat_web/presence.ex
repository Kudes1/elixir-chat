defmodule ElixirChatWeb.Presence do
  @moduledoc """
  Tracks connected visitors. The topic-based design also works across nodes once
  the application's PubSub is configured for a cluster.
  """

  use Phoenix.Presence,
    otp_app: :elixir_chat,
    pubsub_server: ElixirChat.PubSub

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    if topic == "presence:lobby" do
      joins
      |> Map.keys()
      |> Kernel.++(Map.keys(leaves))
      |> Enum.uniq()
      |> Enum.each(fn key ->
        Phoenix.PubSub.local_broadcast(
          ElixirChat.PubSub,
          ElixirChat.OnlineUsers.updates_topic(),
          {__MODULE__, {:metas, key, Map.get(presences, key, [])}}
        )
      end)
    end

    {:ok, state}
  end
end
