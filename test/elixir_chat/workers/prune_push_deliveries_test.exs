defmodule ElixirChat.Workers.PrunePushDeliveriesTest do
  use ElixirChat.DataCase
  use Oban.Testing, repo: ElixirChat.Repo

  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat
  alias ElixirChat.Notifications
  alias ElixirChat.Notifications.PushDelivery
  alias ElixirChat.Repo
  alias ElixirChat.Workers.PrunePushDeliveries

  @retention_days Application.compile_env!(:elixir_chat, ElixirChat.Retention)[
                    :push_deliveries_days
                  ]

  setup do
    user =
      %User{}
      |> User.registration_changeset(%{
        login: "user#{System.unique_integer([:positive])}",
        display_name: "Sender",
        password: "long-test-password"
      })
      |> Repo.insert!()

    previous_config = Application.get_env(:elixir_chat, Notifications, [])
    test_pid = self()

    agent = start_supervised!({Agent, fn -> %{test_pid: test_pid, responses: []} end})

    Application.put_env(
      :elixir_chat,
      Notifications,
      Keyword.merge(previous_config,
        enabled: true,
        adapter: ElixirChat.FakeWebPushAdapter,
        fake_adapter_agent: agent
      )
    )

    on_exit(fn -> Application.put_env(:elixir_chat, Notifications, previous_config) end)

    %{scope: Scope.for_user(user)}
  end

  test "deletes push_deliveries past the configured retention window, keeps recent ones", %{
    scope: scope
  } do
    now = DateTime.utc_now(:second)

    old =
      delivery_fixture!(scope) |> inserted_at!(DateTime.add(now, -(@retention_days + 1) * 86_400))

    recent =
      delivery_fixture!(scope) |> inserted_at!(DateTime.add(now, -(@retention_days - 1) * 86_400))

    assert :ok = perform_job(PrunePushDeliveries, %{})

    refute Repo.get(PushDelivery, old.id)
    assert Repo.get(PushDelivery, recent.id)
  end

  defp inserted_at!(delivery, inserted_at) do
    delivery |> Ecto.Changeset.change(inserted_at: inserted_at) |> Repo.update!()
  end

  # Leaves a durable `push_deliveries` row behind by having the (fake) push
  # adapter fail retryably, same as the "resilient" scenario in
  # notifications_test.exs — success/expiry/discard all delete the row
  # themselves, so there would be nothing left to prune otherwise.
  defp delivery_fixture!(scope) do
    recipient =
      %User{}
      |> User.registration_changeset(%{
        login: "recipient#{System.unique_integer([:positive])}",
        display_name: "Recipient",
        password: "long-test-password"
      })
      |> Repo.insert!()

    {:ok, _subscription} =
      Notifications.subscribe(
        recipient,
        "https://fcm.googleapis.com/#{System.unique_integer([:positive])}",
        "p256dh",
        "auth"
      )

    channel =
      Repo.insert!(
        Chat.Channel.changeset(%Chat.Channel{}, %{
          name: "push-cleanup-#{System.unique_integer([:positive])}",
          kind: :public
        })
      )

    config = Application.fetch_env!(:elixir_chat, Notifications)
    agent = Keyword.fetch!(config, :fake_adapter_agent)
    Agent.update(agent, &%{&1 | responses: [{:error, {:http_error, 503, "unavailable"}}]})

    {:ok, message} =
      Chat.create_message(scope, channel, %{body: "@#{recipient.login} привет"})

    event = Notifications.build_channel_event(Ecto.UUID.generate(), message)
    assert :ok = Notifications.process(:channel, message, event)
    assert_receive {:web_push, _, _}

    Repo.get_by!(PushDelivery, recipient_id: recipient.id, message_id: message.id)
  end
end
