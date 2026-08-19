defmodule ElixirChat.Workers.DeliverPushNotificationTest do
  use ElixirChat.DataCase
  use Oban.Testing, repo: ElixirChat.Repo

  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat
  alias ElixirChat.Notifications
  alias ElixirChat.Notifications.PushDelivery
  alias ElixirChat.Repo
  alias ElixirChat.Workers.DeliverPushNotification

  # `Notifications.process/2` (called from `queue_delivery/2` below) creates
  # the delivery row *and*, since Oban runs in `:inline` testing mode (see
  # config/test.exs), immediately attempts delivery with it, synchronously —
  # so every arrangement here spends one real attempt to get a row that
  # survives (via a retryable failure) before the test's own `perform_job`
  # call exercises the behavior under test with a controlled attempt number.
  setup do
    user = user_fixture()
    recipient = user_fixture()
    previous_config = Application.get_env(:elixir_chat, Notifications, [])
    test_pid = self()

    agent = start_supervised!({Agent, fn -> %{test_pid: test_pid, responses: []} end})

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

    channel =
      Repo.insert!(
        Chat.Channel.changeset(%Chat.Channel{}, %{
          name: "worker-test-#{System.unique_integer([:positive])}",
          kind: :public
        })
      )

    {:ok, subscription} =
      Notifications.subscribe(
        recipient,
        "https://fcm.googleapis.com/worker-test",
        "p256dh",
        "auth"
      )

    {:ok, message} =
      Chat.create_message(Scope.for_user(user), channel, %{body: "@#{recipient.login} привет"})

    %{message: message, subscription: subscription}
  end

  test "a successful delivery deletes the row", ctx do
    delivery = queue_delivery(ctx, retryable_failure())
    assert_receive {:web_push, _, _}

    set_responses([{:ok, :sent}])
    assert :ok = perform_job(DeliverPushNotification, %{"delivery_id" => delivery.id})
    assert_receive {:web_push, _, _}

    refute Repo.get(PushDelivery, delivery.id)
  end

  test "a retryable failure with attempts remaining signals retry and keeps the row", ctx do
    delivery = queue_delivery(ctx, retryable_failure())
    assert_receive {:web_push, _, _}

    set_responses(retryable_failure())

    assert {:error, _reason} =
             perform_job(DeliverPushNotification, %{"delivery_id" => delivery.id},
               attempt: 3,
               max_attempts: 10
             )

    assert_receive {:web_push, _, _}
    assert Repo.get(PushDelivery, delivery.id)
  end

  test "a retryable failure on the final attempt discards the row and emits telemetry", ctx do
    delivery = queue_delivery(ctx, retryable_failure())
    assert_receive {:web_push, _, _}

    set_responses(retryable_failure())
    test_pid = self()

    :telemetry.attach(
      "test-push-retry-exhausted",
      [:elixir_chat, :push, :retry_exhausted],
      fn _event, measurements, meta, _config ->
        send(test_pid, {:retry_exhausted, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-push-retry-exhausted") end)

    assert :ok =
             perform_job(DeliverPushNotification, %{"delivery_id" => delivery.id},
               attempt: 10,
               max_attempts: 10
             )

    assert_receive {:web_push, _, _}
    refute Repo.get(PushDelivery, delivery.id)
    assert_receive {:retry_exhausted, %{attempt_count: 10}, %{delivery_id: delivery_id}}
    assert delivery_id == delivery.id
  end

  test "a delivery that no longer exists is a harmless no-op" do
    assert :ok = perform_job(DeliverPushNotification, %{"delivery_id" => -1})
  end

  defp retryable_failure, do: [{:error, {:http_error, 503, "unavailable"}}]

  defp queue_delivery(%{message: message, subscription: subscription}, responses) do
    set_responses(responses)
    config = Application.fetch_env!(:elixir_chat, Notifications)
    Application.put_env(:elixir_chat, Notifications, Keyword.put(config, :enabled, true))

    event = Notifications.build_channel_event(Ecto.UUID.generate(), message)
    assert :ok = Notifications.process(:channel, message, event)

    Repo.get_by!(PushDelivery, subscription_id: subscription.id, message_id: message.id)
  end

  defp set_responses(responses) do
    config = Application.fetch_env!(:elixir_chat, Notifications)
    agent = Keyword.fetch!(config, :fake_adapter_agent)
    Agent.update(agent, &%{&1 | responses: responses})
  end

  defp user_fixture do
    %User{}
    |> User.registration_changeset(%{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "long-test-password"
    })
    |> Repo.insert!()
  end
end
