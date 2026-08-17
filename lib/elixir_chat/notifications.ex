defmodule ElixirChat.Notifications do
  @moduledoc "Browser push notifications: subscriptions, muting, and message dispatch."

  import Ecto.Query

  require Logger

  alias ElixirChat.Chat
  alias ElixirChat.Chat.{DirectConversation, Message}
  alias ElixirChat.Notifications.{NotificationPreference, PushSubscription, WebPushAdapter}
  alias ElixirChat.Repo

  @pubsub ElixirChat.PubSub

  def subscribe_user(user_id), do: Phoenix.PubSub.subscribe(@pubsub, "chat:user:#{user_id}")
  def user_topic(user_id), do: "chat:user:#{user_id}"

  def subscribe(user, endpoint, p256dh, auth) do
    Repo.insert(
      PushSubscription.changeset(%PushSubscription{}, %{
        user_id: user.id,
        endpoint: endpoint,
        p256dh: p256dh,
        auth: auth
      }),
      on_conflict: {:replace, [:p256dh, :auth, :updated_at]},
      conflict_target: [:user_id, :endpoint]
    )
  end

  def unsubscribe(user, endpoint) do
    Repo.delete_all(
      from subscription in PushSubscription,
        where: subscription.user_id == ^user.id and subscription.endpoint == ^endpoint
    )
  end

  def list_subscriptions(user_id) do
    Repo.all(
      from subscription in PushSubscription,
        where: subscription.user_id == ^user_id,
        order_by: [asc: subscription.id]
    )
  end

  def delete_subscription(subscription) do
    Repo.delete(subscription)
  end

  def delete_all_for_user(user_id) do
    Repo.delete_all(
      from subscription in PushSubscription, where: subscription.user_id == ^user_id
    )
  end

  def set_muted(user, nil, muted) do
    Repo.insert!(
      NotificationPreference.changeset(%NotificationPreference{}, %{
        user_id: user.id,
        channel_id: nil,
        muted: muted
      }),
      on_conflict: {:replace, [:muted, :updated_at]},
      conflict_target: [:user_id, :channel_id]
    )
  end

  def set_muted(user, channel_id, muted) when is_integer(channel_id) do
    Repo.insert!(
      NotificationPreference.changeset(%NotificationPreference{}, %{
        user_id: user.id,
        channel_id: channel_id,
        muted: muted
      }),
      on_conflict: {:replace, [:muted, :updated_at]},
      conflict_target: [:user_id, :channel_id]
    )
  end

  def muted_channel_ids(user_id) do
    Repo.all(
      from preference in NotificationPreference,
        where:
          preference.user_id == ^user_id and preference.muted and
            not is_nil(preference.channel_id),
        select: preference.channel_id
    )
    |> MapSet.new()
  end

  def global_muted?(user_id) do
    Repo.exists?(
      from preference in NotificationPreference,
        where:
          preference.user_id == ^user_id and preference.muted and is_nil(preference.channel_id)
    )
  end

  def muted?(user_id, channel_id) do
    case Repo.one(
           from preference in NotificationPreference,
             where: preference.user_id == ^user_id and preference.channel_id == ^channel_id,
             select: preference.muted
         ) do
      nil -> global_muted?(user_id)
      muted -> muted
    end
  end

  @doc "Asynchronously enqueues push delivery for a freshly created message."
  def enqueue(:channel, %Message{} = message) do
    GenServer.cast(ElixirChat.NotificationSender, {:send, :channel, message})
  end

  def enqueue(:direct, %Message{} = message, %DirectConversation{} = direct) do
    GenServer.cast(ElixirChat.NotificationSender, {:send, :direct, message, direct})
  end

  @doc false
  def process(:channel, %Message{} = message) do
    recipient_ids = Chat.conversation_user_ids(message.channel_id) -- [message.user_id]
    Enum.each(recipient_ids, &send_channel_push(&1, message))
    :ok
  end

  def process(:direct, %Message{} = message, %DirectConversation{} = direct) do
    other_id = DirectConversation.other_user(direct, message.user_id).id
    send_direct_push(other_id, message, direct)
    :ok
  end

  defp send_channel_push(recipient_id, %Message{} = message) do
    if muted?(recipient_id, message.channel_id) do
      Logger.debug("push notification skipped (muted)",
        message_id: message.id,
        recipient_id: recipient_id,
        channel_id: message.channel_id
      )

      :ok
    else
      payload =
        push_payload(
          "##{message.channel.name}: #{message.author_name}",
          message.body,
          "/channels/#{message.channel.public_id}"
        )

      deliver(recipient_id, payload, message)
    end
  end

  defp send_direct_push(recipient_id, %Message{} = message, %DirectConversation{} = direct) do
    if muted?(recipient_id, message.channel_id) do
      Logger.debug("push notification skipped (muted)",
        message_id: message.id,
        recipient_id: recipient_id,
        channel_id: message.channel_id
      )

      :ok
    else
      payload =
        push_payload(
          message.author_name,
          message.body,
          "/direct/#{direct.channel.public_id}"
        )

      deliver(recipient_id, payload, message)
    end
  end

  defp push_payload(title, body, url) do
    %{
      title: title,
      body: preview(body),
      url: url
    }
  end

  defp preview(body) when is_binary(body) do
    if String.length(body) > 240 do
      String.slice(body, 0, 239) <> "…"
    else
      body
    end
  end

  defp deliver(recipient_id, payload, message) do
    if enabled?() do
      subscriptions = list_subscriptions(recipient_id)

      if subscriptions == [] do
        Logger.debug("push notification skipped (no subscriptions)",
          message_id: message.id,
          recipient_id: recipient_id
        )
      end

      payload_json = Jason.encode!(payload)

      Enum.each(subscriptions, fn subscription ->
        deliver_subscription(subscription, payload_json, message)
      end)
    end

    :ok
  end

  defp deliver_subscription(subscription, payload_json, message) do
    subscription_json =
      Jason.encode!(%{
        "endpoint" => subscription.endpoint,
        "keys" => %{"p256dh" => subscription.p256dh, "auth" => subscription.auth}
      })

    case adapter().send_notification(subscription_json, payload_json) do
      {:ok, _response} ->
        Logger.info("push notification delivered",
          message_id: message.id,
          recipient_id: subscription.user_id,
          endpoint: subscription.endpoint
        )

      {:error, :expired} ->
        Logger.info("push subscription expired, removed",
          message_id: message.id,
          recipient_id: subscription.user_id,
          endpoint: subscription.endpoint
        )

        delete_subscription(subscription)

      {:error, {:http_error, status, body}} ->
        Logger.warning(
          "push notification delivery failed with HTTP #{status}: #{inspect(body)}",
          message_id: message.id,
          recipient_id: subscription.user_id,
          endpoint: subscription.endpoint
        )

      {:error, reason} ->
        Logger.warning("push notification delivery failed: #{inspect(reason)}",
          message_id: message.id,
          recipient_id: subscription.user_id,
          endpoint: subscription.endpoint
        )

      unexpected ->
        Logger.warning(
          "push notification returned an unexpected response: #{inspect(unexpected)}",
          message_id: message.id,
          recipient_id: subscription.user_id,
          endpoint: subscription.endpoint
        )
    end
  rescue
    error ->
      Logger.warning(
        "push notification delivery raised #{Exception.format(:error, error, __STACKTRACE__)}",
        message_id: message.id,
        recipient_id: subscription.user_id,
        endpoint: subscription.endpoint
      )
  catch
    kind, reason ->
      Logger.warning(
        "push notification delivery stopped with #{Exception.format(kind, reason, __STACKTRACE__)}",
        message_id: message.id,
        recipient_id: subscription.user_id,
        endpoint: subscription.endpoint
      )
  end

  defp adapter do
    Application.get_env(:elixir_chat, __MODULE__, [])
    |> Keyword.get(:adapter, WebPushAdapter)
  end

  def enabled? do
    Application.get_env(:elixir_chat, __MODULE__, [])[:enabled] == true
  end

  def vapid_public_key do
    Application.get_env(:web_push_elixir, :vapid_public_key, "")
  end
end
