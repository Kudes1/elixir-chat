defmodule ElixirChat.Notifications do
  @moduledoc "Browser push notifications: subscriptions, muting, and message dispatch."

  import Ecto.Query

  require Logger

  alias ElixirChat.Chat
  alias ElixirChat.Chat.{DirectConversation, Message}

  alias ElixirChat.Notifications.{
    NotificationPreference,
    EndpointPolicy,
    PushDelivery,
    PushSubscription,
    WebPushAdapter
  }

  alias ElixirChat.Repo

  @pubsub ElixirChat.PubSub

  def subscribe_user(user_id), do: Phoenix.PubSub.subscribe(@pubsub, "chat:user:#{user_id}")
  def user_topic(user_id), do: "chat:user:#{user_id}"

  def subscribe(user, endpoint, p256dh, auth) do
    changeset =
      PushSubscription.changeset(%PushSubscription{user_id: user.id}, %{
        endpoint: endpoint,
        p256dh: p256dh,
        auth: auth
      })

    Repo.transaction(fn ->
      case Repo.insert(changeset,
             on_conflict: {:replace, [:user_id, :p256dh, :auth, :updated_at]},
             conflict_target: [:endpoint],
             returning: true
           ) do
        {:ok, subscription} ->
          Repo.delete_all(
            from delivery in PushDelivery,
              where:
                delivery.subscription_id == ^subscription.id and
                  delivery.recipient_id != ^user.id
          )

          subscription

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
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
    if enabled?() do
      :ok = process(:channel, message)
      ElixirChat.NotificationSender.wake_up()
    end

    :ok
  end

  def enqueue(:direct, %Message{} = message, %DirectConversation{} = direct) do
    if enabled?() do
      :ok = process(:direct, message, direct)
      ElixirChat.NotificationSender.wake_up()
    end

    :ok
  end

  @doc false
  def process(:channel, %Message{} = message) do
    recipient_ids = Chat.conversation_user_ids(message.channel_id) -- [message.user_id]
    Enum.each(recipient_ids, &queue_channel_push(&1, message))
    :ok
  end

  def process(:direct, %Message{} = message, %DirectConversation{} = direct) do
    other_id = DirectConversation.other_user(direct, message.user_id).id
    queue_direct_push(other_id, message, direct)
    :ok
  end

  defp queue_channel_push(recipient_id, %Message{} = message) do
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

      queue_deliveries(recipient_id, payload, message)
    end
  end

  defp queue_direct_push(recipient_id, %Message{} = message, %DirectConversation{} = direct) do
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

      queue_deliveries(recipient_id, payload, message)
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

  defp queue_deliveries(recipient_id, payload, message) do
    if enabled?() do
      subscriptions = list_subscriptions(recipient_id)

      if subscriptions == [] do
        Logger.debug("push notification skipped (no subscriptions)",
          message_id: message.id,
          recipient_id: recipient_id
        )
      end

      now = DateTime.utc_now(:second)

      rows =
        Enum.map(subscriptions, fn subscription ->
          %{
            subscription_id: subscription.id,
            recipient_id: recipient_id,
            message_id: message.id,
            payload: payload,
            attempt_count: 0,
            available_at: now,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(PushDelivery, rows,
        on_conflict: :nothing,
        conflict_target: [:subscription_id, :message_id]
      )
    end

    :ok
  end

  @doc false
  def due_delivery_ids(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now(:second)

    Repo.all(
      from delivery in PushDelivery,
        where: delivery.available_at <= ^now,
        order_by: [asc: delivery.id],
        limit: ^limit,
        select: delivery.id
    )
  end

  @doc false
  def deliver_delivery(delivery_id) do
    delivery =
      Repo.one(
        from delivery in PushDelivery,
          join: subscription in assoc(delivery, :subscription),
          where: delivery.id == ^delivery_id,
          preload: [subscription: subscription]
      )

    case delivery do
      nil ->
        :gone

      %PushDelivery{
        recipient_id: user_id,
        subscription: %PushSubscription{user_id: user_id}
      } = delivery ->
        if EndpointPolicy.valid?(delivery.subscription.endpoint) do
          deliver_subscription(delivery)
        else
          Logger.warning("invalid push subscription removed before delivery",
            recipient_id: user_id,
            endpoint_id: endpoint_fingerprint(delivery.subscription.endpoint)
          )

          delete_subscription(delivery.subscription)
          :invalid_endpoint
        end

      %PushDelivery{} = stale ->
        Repo.delete_all(from delivery in PushDelivery, where: delivery.id == ^stale.id)
        :stale
    end
  end

  @doc false
  def fail_delivery(delivery_id, reason) do
    case Repo.get(PushDelivery, delivery_id) do
      nil -> :gone
      delivery -> retry_delivery(delivery, reason)
    end
  end

  defp deliver_subscription(%PushDelivery{subscription: subscription} = delivery) do
    subscription_json =
      Jason.encode!(%{
        "endpoint" => subscription.endpoint,
        "keys" => %{"p256dh" => subscription.p256dh, "auth" => subscription.auth}
      })

    payload_json = Jason.encode!(delivery.payload)

    case adapter().send_notification(subscription_json, payload_json) do
      {:ok, _response} ->
        Logger.info("push notification delivered",
          message_id: delivery.message_id,
          recipient_id: subscription.user_id,
          endpoint_id: endpoint_fingerprint(subscription.endpoint)
        )

        delete_delivery(delivery.id)
        :ok

      {:error, :expired} ->
        Logger.info("push subscription expired, removed",
          message_id: delivery.message_id,
          recipient_id: subscription.user_id,
          endpoint_id: endpoint_fingerprint(subscription.endpoint)
        )

        delete_subscription(subscription)

        :expired

      {:error, {:http_error, status, body}} ->
        Logger.warning(
          "push notification delivery failed with HTTP #{status}",
          message_id: delivery.message_id,
          recipient_id: subscription.user_id,
          endpoint_id: endpoint_fingerprint(subscription.endpoint)
        )

        retry_delivery(delivery, {:http_error, status, body})

      {:error, reason} ->
        Logger.warning("push notification delivery failed: #{inspect(reason)}",
          message_id: delivery.message_id,
          recipient_id: subscription.user_id,
          endpoint_id: endpoint_fingerprint(subscription.endpoint)
        )

        retry_delivery(delivery, reason)

      unexpected ->
        Logger.warning(
          "push notification returned an unexpected response: #{inspect(unexpected)}",
          message_id: delivery.message_id,
          recipient_id: subscription.user_id,
          endpoint_id: endpoint_fingerprint(subscription.endpoint)
        )

        retry_delivery(delivery, {:unexpected_response, unexpected})
    end
  rescue
    error ->
      Logger.warning(
        "push notification delivery raised #{Exception.format(:error, error, __STACKTRACE__)}",
        message_id: delivery.message_id,
        recipient_id: subscription.user_id,
        endpoint_id: endpoint_fingerprint(subscription.endpoint)
      )

      retry_delivery(delivery, error)
  catch
    kind, reason ->
      Logger.warning(
        "push notification delivery stopped with #{Exception.format(kind, reason, __STACKTRACE__)}",
        message_id: delivery.message_id,
        recipient_id: subscription.user_id,
        endpoint_id: endpoint_fingerprint(subscription.endpoint)
      )

      retry_delivery(delivery, {kind, reason})
  end

  defp retry_delivery(delivery, reason) do
    attempts = delivery.attempt_count + 1
    error = inspect(reason, limit: 20, printable_limit: 500) |> String.slice(0, 1_000)

    if attempts >= 10 do
      delete_delivery(delivery.id)

      :telemetry.execute(
        [:elixir_chat, :push, :retry_exhausted],
        %{attempt_count: attempts},
        %{delivery_id: delivery.id, message_id: delivery.message_id, error: error}
      )

      :discarded
    else
      delay_seconds = min(round(:math.pow(2, min(attempts - 1, 8))), 300)

      Repo.update_all(
        from(queued in PushDelivery, where: queued.id == ^delivery.id),
        set: [
          attempt_count: attempts,
          available_at: DateTime.add(DateTime.utc_now(:second), delay_seconds, :second),
          last_error: error,
          updated_at: DateTime.utc_now(:second)
        ]
      )

      :retry
    end
  end

  defp delete_delivery(delivery_id) do
    Repo.delete_all(from delivery in PushDelivery, where: delivery.id == ^delivery_id)
  end

  defp endpoint_fingerprint(endpoint) do
    :crypto.hash(:sha256, endpoint)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
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
