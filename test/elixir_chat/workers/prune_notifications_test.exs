defmodule ElixirChat.Workers.PruneNotificationsTest do
  use ElixirChat.DataCase
  use Oban.Testing, repo: ElixirChat.Repo

  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat
  alias ElixirChat.Notifications.Notification
  alias ElixirChat.Repo
  alias ElixirChat.Workers.PruneNotifications

  @retention_days Application.compile_env!(:elixir_chat, ElixirChat.Retention)[
                    :notifications_read_days
                  ]

  setup do
    owner =
      %User{}
      |> User.registration_changeset(%{
        login: "owner#{System.unique_integer([:positive])}",
        display_name: "Owner",
        password: "long-test-password"
      })
      |> Repo.insert!()

    %{scope: Scope.for_user(owner)}
  end

  test "deletes read notifications past the configured retention window, keeps recent ones", %{
    scope: scope
  } do
    other = user_fixture()
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)

    {:ok, old_message} = Chat.create_message(scope, direct.channel, %{body: "старое"})
    {:ok, recent_message} = Chat.create_message(scope, direct.channel, %{body: "новое"})

    assert {:ok, 0} =
             Chat.mark_conversation_read(
               Scope.for_user(other),
               direct.channel.id,
               recent_message.id
             )

    now = DateTime.utc_now(:second)

    old_notification =
      Notification
      |> Repo.get_by!(message_id: old_message.id)
      |> backdate!(DateTime.add(now, -(@retention_days + 1) * 86_400))

    recent_notification =
      Notification
      |> Repo.get_by!(message_id: recent_message.id)
      |> backdate!(DateTime.add(now, -(@retention_days - 1) * 86_400))

    assert :ok = perform_job(PruneNotifications, %{})

    refute Repo.get(Notification, old_notification.id)
    assert Repo.get(Notification, recent_notification.id)
  end

  test "never deletes unread notifications, no matter their age", %{scope: scope} do
    other = user_fixture()
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)
    {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "непрочитанное"})

    notification =
      Notification
      |> Repo.get_by!(message_id: message.id)
      |> backdate!(DateTime.add(DateTime.utc_now(:second), -(@retention_days + 365) * 86_400))

    assert :ok = perform_job(PruneNotifications, %{})
    assert Repo.get(Notification, notification.id)
  end

  defp backdate!(notification, inserted_at) do
    notification |> Ecto.Changeset.change(inserted_at: inserted_at) |> Repo.update!()
  end

  defp user_fixture do
    %User{}
    |> User.registration_changeset(%{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Other",
      password: "long-test-password"
    })
    |> Repo.insert!()
  end
end
