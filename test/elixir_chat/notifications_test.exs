defmodule ElixirChat.NotificationsTest do
  use ElixirChat.DataCase

  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat
  alias ElixirChat.Notifications
  alias ElixirChat.Notifications.NotificationPreference
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
      Notifications.subscribe(user, "https://push/endpoint-1", "p256dh-a", "auth-a")

    assert subscription.endpoint == "https://push/endpoint-1"
    assert [stored] = Notifications.list_subscriptions(user.id)
    assert stored.endpoint == "https://push/endpoint-1"

    assert {:ok, _subscription} =
             Notifications.subscribe(user, "https://push/endpoint-1", "p256dh-b", "auth-b")

    assert length(Notifications.list_subscriptions(user.id)) == 1

    assert {:ok, _subscription} =
             Notifications.subscribe(user, "https://push/endpoint-2", "p256dh-c", "auth-c")

    assert length(Notifications.list_subscriptions(user.id)) == 2

    Notifications.unsubscribe(user, "https://push/endpoint-1")
    assert [remaining] = Notifications.list_subscriptions(user.id)
    assert remaining.endpoint == "https://push/endpoint-2"
  end

  test "push subscriptions reject missing or blank browser credentials", %{user: user} do
    assert {:error, changeset} = Notifications.subscribe(user, "https://push/endpoint", nil, "")
    assert %{p256dh: ["can't be blank"], auth: ["can't be blank"]} = errors_on(changeset)
    assert Notifications.list_subscriptions(user.id) == []
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

  test "channel delivery sends JSON only to unmuted recipients and limits the preview", %{
    scope: scope
  } do
    author = scope.user
    recipient = user_fixture()
    channel = channel_fixture(%{name: "push-channel"})
    subscribe!(author, "author")
    subscribe!(recipient, "recipient")

    {:ok, message} = Chat.create_message(scope, channel, %{body: String.duplicate("🙂", 300)})
    assert message.author_name == author.display_name

    enable_push([])
    assert :ok = Notifications.process(:channel, message)

    assert_receive {:web_push, subscription_json, payload_json}

    assert %{"endpoint" => "https://push/recipient", "keys" => keys} =
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
    assert :ok = Notifications.process(:channel, message)
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
    assert :ok = Notifications.process(:direct, message, direct)

    assert_receive {:web_push, subscription_json, payload_json}
    assert Jason.decode!(subscription_json)["endpoint"] == "https://push/other"

    assert %{"title" => "Ирина", "body" => "привет", "url" => url} =
             Jason.decode!(payload_json)

    assert url == "/direct/#{direct.channel.public_id}"
    refute_receive {:web_push, _, _}, 20
  end

  test "expired subscriptions are removed", %{scope: scope} do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "expired-push"})
    subscribe!(recipient, "expired")
    {:ok, message} = Chat.create_message(scope, channel, %{body: "привет"})

    enable_push([{:error, :expired}])
    assert :ok = Notifications.process(:channel, message)
    assert_receive {:web_push, _, _}
    assert Notifications.list_subscriptions(recipient.id) == []
  end

  test "HTTP errors and exceptions do not restart the sender or block later jobs", %{scope: scope} do
    recipient = user_fixture()
    channel = channel_fixture(%{name: "resilient-push"})
    subscribe!(recipient, "resilient")
    {:ok, message} = Chat.create_message(scope, channel, %{body: "привет"})

    enable_push([
      {:error, {:http_error, 503, "unavailable"}},
      {:raise, "encryption failed"},
      {:ok, :sent}
    ])

    sender = Process.whereis(ElixirChat.NotificationSender)

    for _ <- 1..3 do
      Notifications.enqueue(:channel, message)
      :sys.get_state(sender)
    end

    for _ <- 1..3, do: assert_receive({:web_push, _, _})
    assert Process.alive?(sender)
    assert Process.whereis(ElixirChat.NotificationSender) == sender
  end

  defp subscribe!(user, suffix) do
    {:ok, subscription} =
      Notifications.subscribe(
        user,
        "https://push/#{suffix}",
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
end
