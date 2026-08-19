defmodule ElixirChat.Notifications do
  @moduledoc "Browser push notifications: subscriptions, muting, and message dispatch."

  import Ecto.Query

  require Logger

  alias ElixirChat.Chat.{ConversationRead, DirectConversation, Message}

  alias ElixirChat.Notifications.{
    NotificationPreference,
    EndpointPolicy,
    Notification,
    PushDelivery,
    PushSubscription,
    WebPushAdapter
  }

  alias ElixirChat.Workers.DeliverPushNotification

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

  @doc """
  Whether `notification` has been read, and since when — derived from the
  recipient's existing read cursor for that conversation
  (`ElixirChat.Chat.ConversationRead`) rather than a second, independently
  written column on `Notification` itself. The cursor is already the source
  of truth for "read" (`ElixirChat.Chat.upsert_read_cursor/5`); a duplicate
  `read_at` write path here would only invite the two to drift apart.

  Returns `nil` when unread. There is no notification-center UI consuming
  this yet — `seen_at` is deferred entirely until one exists — but "is a
  mention/DM notification read" is already a well-defined question via the
  existing read cursor, so it is answered here now rather than invented
  ad hoc once a consumer shows up.
  """
  def read_at(%Notification{recipient_id: recipient_id, channel_id: channel_id} = notification) do
    Repo.one(
      from read in ConversationRead,
        where:
          read.user_id == ^recipient_id and read.channel_id == ^channel_id and
            not is_nil(read.last_read_message_id) and
            read.last_read_message_id >= ^notification.message_id,
        select: read.last_read_at
    )
  end

  @doc "Enqueues durable push delivery jobs for a freshly created message."
  def enqueue(:channel, %Message{} = message) do
    if enabled?(), do: :ok = process(:channel, message)

    :ok
  end

  def enqueue(:direct, %Message{} = message, %DirectConversation{} = direct) do
    if enabled?(), do: :ok = process(:direct, message, direct)

    :ok
  end

  # Narrowed to durable Notification recipients (currently: @mention only —
  # see ElixirChat.Chat.persist_message_transaction/4) rather than every
  # conversation member, so an ordinary message to a 200-person channel does
  # not queue 199 push deliveries.
  @doc false
  def process(:channel, %Message{} = message) do
    recipient_ids = mentioned_recipient_ids(message.id)
    Enum.each(recipient_ids, &queue_channel_push(&1, message))
    :ok
  end

  def process(:direct, %Message{} = message, %DirectConversation{} = direct) do
    other_id = DirectConversation.other_user(direct, message.user_id).id
    queue_direct_push(other_id, message, direct)
    :ok
  end

  defp mentioned_recipient_ids(message_id) do
    Repo.all(
      from notification in Notification,
        where: notification.message_id == ^message_id and notification.type == "mention",
        select: notification.recipient_id
    )
  end

  @doc "Whether `recipient_id` was `@mention`-ed by `message_id`, for NotificationPolicy priority (see ChatLive.maybe_notify_channel_message/2)."
  def mentioned?(message_id, recipient_id) do
    Repo.exists?(
      from notification in Notification,
        where:
          notification.message_id == ^message_id and notification.recipient_id == ^recipient_id and
            notification.type == "mention"
    )
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
            inserted_at: now,
            updated_at: now
          }
        end)

      insert_deliveries_with_jobs(rows)
    end

    :ok
  end

  # Inserting the delivery row and its Oban delivery job in the same
  # transaction is what makes the job durable: if the transaction never
  # commits, neither exists, and if it does, the job is guaranteed to exist
  # alongside the row it delivers — no separate "wake up the poller" signal
  # to lose. `on_conflict: :nothing` + `returning: true` means Postgres only
  # returns rows actually inserted, so an idempotent replay (the same message
  # queued twice) never queues a duplicate job for a delivery that already
  # has one.
  defp insert_deliveries_with_jobs([]), do: :ok

  defp insert_deliveries_with_jobs(rows) do
    Repo.transaction(fn ->
      {_count, inserted} =
        Repo.insert_all(PushDelivery, rows,
          on_conflict: :nothing,
          conflict_target: [:subscription_id, :message_id],
          returning: [:id]
        )

      inserted
      |> Enum.map(&DeliverPushNotification.new(%{delivery_id: &1.id}))
      |> Oban.insert_all()
    end)

    :ok
  end

  @default_cleanup_batch_size 1000

  @doc """
  Deletes one batch of `PushDelivery` rows older than `cutoff` (by
  `inserted_at`), regardless of outcome. This is a safety net, not the
  primary cleanup path: a delivery row normally deletes itself the moment it
  reaches a terminal state (delivered, stale, expired subscription, or
  discarded after `ElixirChat.Workers.DeliverPushNotification`'s final
  attempt — see `delete_delivery/1`, `discard_delivery/2`). A row surviving
  past `cutoff` means something outside that lifecycle went wrong (e.g. its
  Oban job was lost), so this exists to keep such rows from lingering
  forever rather than to do the everyday cleanup work.

  Returns the number of rows deleted; loop via
  `ElixirChat.Workers.BatchDelete.run/1` for a full sweep.
  """
  def delete_stale_deliveries_before(cutoff, batch_size \\ @default_cleanup_batch_size) do
    {count, _} =
      Repo.delete_all(
        from delivery in PushDelivery,
          where:
            delivery.id in subquery(
              from d in PushDelivery,
                where: d.inserted_at < ^cutoff,
                select: d.id,
                limit: ^batch_size
            )
      )

    count
  end

  @doc """
  Deletes one batch of `Notification` rows that are both read (per
  `read_at/1`'s join against `ElixirChat.Chat.ConversationRead`, evaluated
  inline here for a set-based delete) and older than `cutoff` (by
  `inserted_at`, the notification's own age — not how recently the
  recipient last read the conversation, which would keep pushing the cutoff
  out for any conversation that stays active). Unread notifications are
  never matched by the join and so are never deleted, no matter their age —
  the whole reason `read_at/1` exists as a real join instead of a boolean.

  Returns the number of rows deleted; loop via
  `ElixirChat.Workers.BatchDelete.run/1` for a full sweep.
  """
  def delete_read_notifications_before(cutoff, batch_size \\ @default_cleanup_batch_size) do
    {count, _} =
      Repo.delete_all(
        from notification in Notification,
          where:
            notification.id in subquery(
              from n in Notification,
                join: read in ConversationRead,
                on:
                  read.user_id == n.recipient_id and read.channel_id == n.channel_id and
                    not is_nil(read.last_read_message_id) and
                    read.last_read_message_id >= n.message_id,
                where: n.inserted_at < ^cutoff,
                select: n.id,
                limit: ^batch_size
            )
      )

    count
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

  @doc """
  Gives up on a delivery that is still failing on its final Oban attempt (see
  `ElixirChat.Workers.DeliverPushNotification`) — deletes the row so it does
  not linger forever with no more attempts left to retry it, mirroring the
  old manual "discard after 10 attempts" behavior now that Oban owns attempt
  counting.
  """
  def discard_delivery(delivery_id, attempt_count) do
    case Repo.get(PushDelivery, delivery_id) do
      nil ->
        :ok

      delivery ->
        :telemetry.execute(
          [:elixir_chat, :push, :retry_exhausted],
          %{attempt_count: attempt_count},
          %{delivery_id: delivery.id, message_id: delivery.message_id}
        )

        delete_delivery(delivery.id)
        :ok
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

  # Leaves the delivery row untouched — Oban owns attempt counting and backoff
  # scheduling for the job that will call this again (or, on the final
  # attempt, `discard_delivery/2` instead — see
  # `ElixirChat.Workers.DeliverPushNotification`).
  defp retry_delivery(_delivery, _reason), do: :retry

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
