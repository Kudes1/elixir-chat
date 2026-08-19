defmodule ElixirChat.NotificationsTest do
  use ElixirChat.DataCase

  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat
  alias ElixirChat.Notifications
  alias ElixirChat.Notifications.{Notification, NotificationPreference, PushDelivery}
  alias ElixirChat.Repo

  setup do
    user =
      %User{}
      |> User.registration_changeset(%{
        login: "user#{System.unique_integer([:positive])}",
        display_name: "Ирина",
        password: "long-test-password"
      })
      |> Repo.insert!()

    previous_config = Application.get_env(:elixir_chat, Notifications, [])

    test_pid = self()

    start_supervised!({Agent, fn -> %{test_pid: test_pid, responses: []} end})
    |> then(fn agent ->
      Application.put_env(
        :elixir_chat,
        Notifications,
        Keyword.merge(previous_config,
          enabled: false,
          adapter: ElixirChat.FakeWebPushAdapter,
          fake_adapter_agent: agent
        )
      )

      on_exit(fn -> Application.put_env(:elixir_chat, Notifications, previous_config) end)
    end)

    %{scope: Scope.for_user(user), user: user}
  end

  defp user_fixture(attrs \\ %{}) do
    defaults = %{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "long-test-password"
    }

    %User{}
    |> User.registration_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  test "push subscriptions are stored and removed per user and endpoint", %{user: user} do
    {:ok, subscription} =
      Notifications.subscribe(user, "https://fcm.googleapis.com/endpoint-1", "p256dh-a", "auth-a")

    assert subscription.endpoint == "https://fcm.googleapis.com/endpoint-1"
    assert [stored] = Notifications.list_subscriptions(user.id)
    assert stored.endpoint == "https://fcm.googleapis.com/endpoint-1"

    assert {:ok, _subscription} =
             Notifications.subscribe(
               user,
               "https://fcm.googleapis.com/endpoint-1",
               "p256dh-b",
               "auth-b"
             )

    assert length(Notifications.list_subscriptions(user.id)) == 1

    assert {:ok, _subscription} =
             Notifications.subscribe(
               user,
               "https://fcm.googleapis.com/endpoint-2",
               "p256dh-c",
               "auth-c"
             )

    assert length(Notifications.list_subscriptions(user.id)) == 2

    Notifications.unsubscribe(user, "https://fcm.googleapis.com/endpoint-1")
    assert [remaining] = Notifications.list_subscriptions(user.id)
    assert remaining.endpoint == "https://fcm.googleapis.com/endpoint-2"
  end

  test "push subscriptions reject missing or blank browser credentials", %{user: user} do
    assert {:error, changeset} =
             Notifications.subscribe(user, "https://fcm.googleapis.com/endpoint", nil, "")

    assert %{p256dh: ["can't be blank"], auth: ["can't be blank"]} = errors_on(changeset)
    assert Notifications.list_subscriptions(user.id) == []
  end

  test "a browser endpoint is transferred to the currently signed-in user", %{user: user} do
    next_user = user_fixture()
    endpoint = "https://fcm.googleapis.com/shared-browser"

    assert {:ok, first} = Notifications.subscribe(user, endpoint, "first-key", "first-auth")

    channel = channel_fixture(%{name: "ownership-transfer"})

    {:ok, message} =
      Chat.create_message(Scope.for_user(next_user), channel, %{
        body: "@#{user.login} private preview"
      })

    # A retryable failure, so the delivery row survives the (now-synchronous)
    # delivery attempt made by `process/2` itself — otherwise there would be
    # nothing left in `push_deliveries` for the resubscribe below to clean up.
    enable_push([{:error, {:http_error, 503, "unavailable"}}])
    assert :ok = Notifications.process(:channel, message, channel_event(message))
    assert_receive {:web_push, _, _}
    assert Repo.aggregate(PushDelivery, :count) == 1

    assert {:ok, transferred} =
             Notifications.subscribe(next_user, endpoint, "next-key", "next-auth")

    assert transferred.id == first.id
    assert transferred.user_id == next_user.id
    assert transferred.p256dh == "next-key"
    assert Notifications.list_subscriptions(user.id) == []
    assert [owned] = Notifications.list_subscriptions(next_user.id)
    assert owned.id == first.id
    assert Repo.aggregate(PushDelivery, :count) == 0
  end

  test "push subscriptions reject untrusted or non-HTTPS endpoints", %{user: user} do
    for endpoint <- [
          "http://fcm.googleapis.com/push",
          "https://127.0.0.1/push",
          "https://fcm.googleapis.com.evil.example/push",
          "https://user@fcm.googleapis.com/push"
        ] do
      assert {:error, changeset} =
               Notifications.subscribe(user, endpoint, "browser-key", "browser-auth")

      assert "is not an allowed Web Push endpoint" in errors_on(changeset).endpoint
    end
  end

  test "muting a channel records a preference and is reported in muted_channel_ids",
       %{user: user} do
    channel = channel_fixture(%{name: "mute-channel"})

    assert Notifications.muted_channel_ids(user.id) == MapSet.new()

    Notifications.set_muted(user, channel.id, true)
    assert Notifications.muted?(user.id, channel.id)
    assert MapSet.member?(Notifications.muted_channel_ids(user.id), channel.id)

    Notifications.set_muted(user, channel.id, false)
    refute Notifications.muted?(user.id, channel.id)
  end

  test "global mute applies to conversations without a specific preference", %{user: user} do
    channel = channel_fixture(%{name: "global-mute-channel"})

    Notifications.set_muted(user, nil, true)
    assert Notifications.muted?(user.id, channel.id)

    Notifications.set_muted(user, channel.id, false)
    refute Notifications.muted?(user.id, channel.id)

    Notifications.set_muted(user, nil, false)

    assert Repo.aggregate(
             from(preference in NotificationPreference,
               where: preference.user_id == ^user.id and is_nil(preference.channel_id)
             ),
             :count
           ) == 1
  end

  test "an ordinary channel message queues no push delivery for non-mentioned recipients", %{
    scope: scope
  } do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "no-mention-push"})
    subscribe!(recipient, "no-mention")

    {:ok, message} = Chat.create_message(scope, channel, %{body: "обычное сообщение всем"})

    enable_push([])
    assert :ok = Notifications.process(:channel, message, channel_event(message))
    assert Repo.aggregate(PushDelivery, :count) == 0
  end

  test "channel delivery sends JSON only to unmuted recipients and limits the preview", %{
    scope: scope
  } do
    author = scope.user
    recipient = user_fixture()
    channel = channel_fixture(%{name: "push-channel"})
    subscribe!(author, "author")
    subscribe!(recipient, "recipient")

    {:ok, message} =
      Chat.create_message(scope, channel, %{
        body: "@#{recipient.login} " <> String.duplicate("🙂", 300)
      })

    assert message.author_name == author.display_name

    enable_push([])
    assert :ok = Notifications.process(:channel, message, channel_event(message))

    assert_receive {:web_push, subscription_json, payload_json}

    assert %{"endpoint" => "https://fcm.googleapis.com/recipient", "keys" => keys} =
             Jason.decode!(subscription_json)

    assert keys == %{"p256dh" => "p256dh-recipient", "auth" => "auth-recipient"}

    assert %{
             "title" => "#push-channel: Ирина",
             "body" => body,
             "url" => "/channels/" <> _public_id
           } = Jason.decode!(payload_json)

    assert String.length(body) == 240
    assert String.ends_with?(body, "…")
    refute_receive {:web_push, _, _}, 20

    Notifications.set_muted(recipient, channel.id, true)
    assert :ok = Notifications.process(:channel, message, channel_event(message))
    refute_receive {:web_push, _, _}, 20
  end

  test "direct delivery targets the other participant", %{user: user} do
    other = user_fixture()
    subscribe!(user, "author")
    subscribe!(other, "other")

    {:ok, direct} =
      Chat.get_or_create_direct_conversation(Scope.for_user(user), other.id)

    {:ok, message} =
      Chat.create_message(Scope.for_user(user), direct.channel, %{body: "привет"})

    enable_push([])
    assert :ok = Notifications.process(:direct, message, direct, direct_event(message, direct))

    assert_receive {:web_push, subscription_json, payload_json}
    assert Jason.decode!(subscription_json)["endpoint"] == "https://fcm.googleapis.com/other"

    assert %{"title" => "Ирина", "body" => "привет", "url" => url} =
             Jason.decode!(payload_json)

    assert url == "/direct/#{direct.channel.public_id}"
    refute_receive {:web_push, _, _}, 20
  end

  test "expired subscriptions are removed", %{scope: scope} do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "expired-push"})
    subscribe!(recipient, "expired")
    {:ok, message} = Chat.create_message(scope, channel, %{body: "@#{recipient.login} привет"})

    enable_push([{:error, :expired}])
    assert :ok = Notifications.process(:channel, message, channel_event(message))
    assert_receive {:web_push, _, _}
    assert Notifications.list_subscriptions(recipient.id) == []
  end

  test "a transient failure leaves the delivery row in place for Oban to retry", %{scope: scope} do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "resilient-push"})
    subscribe!(recipient, "resilient")
    {:ok, message} = Chat.create_message(scope, channel, %{body: "@#{recipient.login} привет"})

    enable_push([{:error, {:http_error, 503, "unavailable"}}])

    assert :ok = Notifications.process(:channel, message, channel_event(message))
    assert_receive {:web_push, _, _}

    assert %PushDelivery{} = Repo.one(PushDelivery)
  end

  test "exceptions in one delivery do not block later jobs", %{scope: scope} do
    first_recipient = user_fixture()
    second_recipient = user_fixture()
    channel = channel_fixture(%{name: "concurrent-push"})
    subscribe!(first_recipient, "first")
    subscribe!(second_recipient, "second")

    {:ok, message} =
      Chat.create_message(scope, channel, %{
        body: "@#{first_recipient.login} @#{second_recipient.login} привет"
      })

    enable_push([{:raise, "encryption failed"}, {:ok, :sent}])
    assert :ok = Notifications.process(:channel, message, channel_event(message))

    assert_receive {:web_push, _, _}
    assert_receive {:web_push, _, _}
    assert Repo.aggregate(PushDelivery, :count) == 1
  end

  test "mentioned?/2 reports whether a recipient was actually @mentioned by a message", %{
    scope: scope
  } do
    channel = channel_fixture(%{name: "mentioned-check"})
    mentioned = user_fixture()
    bystander = user_fixture()

    {:ok, message} =
      Chat.create_message(scope, channel, %{body: "@#{mentioned.login} привет"})

    assert Notifications.mentioned?(message.id, mentioned.id)
    refute Notifications.mentioned?(message.id, bystander.id)
  end

  test "read_at/1 derives read status from the recipient's existing read cursor", %{
    scope: scope
  } do
    other = user_fixture()
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)
    {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "привет"})

    assert %Notification{type: "direct_message", recipient_id: recipient_id} =
             notification =
             Repo.get_by!(Notification, message_id: message.id)

    assert recipient_id == other.id
    assert Notifications.read_at(notification) == nil

    assert {:ok, 0} =
             Chat.mark_conversation_read(Scope.for_user(other), direct.channel.id, message.id)

    assert %DateTime{} = Notifications.read_at(notification)
  end

  test "delete_stale_deliveries_before/2 deletes push_deliveries older than the cutoff regardless of outcome",
       %{scope: scope} do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "stale-push-cleanup"})
    subscribe!(recipient, "stale-cleanup")
    {:ok, message} = Chat.create_message(scope, channel, %{body: "@#{recipient.login} привет"})

    enable_push([{:error, {:http_error, 503, "unavailable"}}])
    assert :ok = Notifications.process(:channel, message, channel_event(message))
    assert_receive {:web_push, _, _}

    assert %PushDelivery{} = delivery = Repo.one(PushDelivery)
    cutoff = DateTime.utc_now(:second)

    delivery
    |> Ecto.Changeset.change(inserted_at: DateTime.add(cutoff, -3600))
    |> Repo.update!()

    assert Notifications.delete_stale_deliveries_before(cutoff) == 1
    refute Repo.get(PushDelivery, delivery.id)
  end

  test "delete_stale_deliveries_before/2 leaves recent deliveries alone", %{scope: scope} do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "recent-push-cleanup"})
    subscribe!(recipient, "recent-cleanup")
    {:ok, message} = Chat.create_message(scope, channel, %{body: "@#{recipient.login} привет"})

    enable_push([{:error, {:http_error, 503, "unavailable"}}])
    assert :ok = Notifications.process(:channel, message, channel_event(message))
    assert_receive {:web_push, _, _}

    cutoff = DateTime.add(DateTime.utc_now(:second), -3600)
    assert Notifications.delete_stale_deliveries_before(cutoff) == 0
    assert Repo.aggregate(PushDelivery, :count) == 1
  end

  test "delete_read_notifications_before/2 deletes only read notifications older than the cutoff",
       %{scope: scope} do
    other = user_fixture()
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)
    {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "привет"})

    notification = Repo.get_by!(Notification, message_id: message.id)

    assert {:ok, 0} =
             Chat.mark_conversation_read(Scope.for_user(other), direct.channel.id, message.id)

    cutoff = DateTime.utc_now(:second)

    notification
    |> Ecto.Changeset.change(inserted_at: DateTime.add(cutoff, -3600))
    |> Repo.update!()

    assert Notifications.delete_read_notifications_before(cutoff) == 1
    refute Repo.get(Notification, notification.id)
  end

  test "delete_read_notifications_before/2 never deletes unread notifications, no matter their age",
       %{scope: scope} do
    other = user_fixture()
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)
    {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "привет"})

    notification = Repo.get_by!(Notification, message_id: message.id)
    cutoff = DateTime.utc_now(:second)

    notification
    |> Ecto.Changeset.change(inserted_at: DateTime.add(cutoff, -3600))
    |> Repo.update!()

    assert Notifications.delete_read_notifications_before(cutoff) == 0
    assert Repo.get(Notification, notification.id)
  end

  test "delete_read_notifications_before/2 batches so a large backlog is deleted in bounded chunks",
       %{scope: scope} do
    other = user_fixture()
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)

    messages =
      for i <- 1..25 do
        {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "привет #{i}"})
        message
      end

    assert {:ok, 0} =
             Chat.mark_conversation_read(
               Scope.for_user(other),
               direct.channel.id,
               List.last(messages).id
             )

    cutoff = DateTime.utc_now(:second)

    notifications =
      Enum.map(messages, fn message ->
        Notification
        |> Repo.get_by!(message_id: message.id)
        |> Ecto.Changeset.change(inserted_at: DateTime.add(cutoff, -3600))
        |> Repo.update!()
      end)

    assert Notifications.delete_read_notifications_before(cutoff, 10) == 10
    assert Notifications.delete_read_notifications_before(cutoff, 10) == 10
    assert Notifications.delete_read_notifications_before(cutoff, 10) == 5
    assert Notifications.delete_read_notifications_before(cutoff, 10) == 0

    Enum.each(notifications, fn notification -> refute Repo.get(Notification, notification.id) end)
  end

  defp subscribe!(user, suffix) do
    {:ok, subscription} =
      Notifications.subscribe(
        user,
        "https://fcm.googleapis.com/#{suffix}",
        "p256dh-#{suffix}",
        "auth-#{suffix}"
      )

    subscription
  end

  defp enable_push(responses) do
    config = Application.fetch_env!(:elixir_chat, Notifications)
    agent = Keyword.fetch!(config, :fake_adapter_agent)
    Agent.update(agent, &%{&1 | responses: responses})
    Application.put_env(:elixir_chat, Notifications, Keyword.put(config, :enabled, true))
  end

  defp channel_fixture(attrs) do
    defaults = %{name: "channel-#{System.unique_integer([:positive])}", kind: :public}
    Repo.insert!(Chat.Channel.changeset(%Chat.Channel{}, Map.merge(defaults, attrs)))
  end

  defp channel_event(message) do
    Notifications.build_channel_event(Ecto.UUID.generate(), message)
  end

  defp direct_event(message, direct) do
    Notifications.build_direct_event(Ecto.UUID.generate(), message, direct)
  end
end
