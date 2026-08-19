defmodule ElixirChat.ObanDurabilityTest do
  @moduledoc """
  The acceptance test from `tasks/06-oban-migration.md`: a job created
  alongside a committed business event must survive independently of any
  in-memory process — the row in `oban_jobs` is what's durable, not a
  GenServer's state. `mix test` runs with Oban in `:inline` testing mode
  (see config/test.exs) precisely so the rest of the suite gets the old
  poll-based dispatcher's synchronous-for-tests behavior for free; this test
  explicitly switches to `:manual` to prove the *real*, DB-backed path — the
  one actually used outside of tests — works: the job is really persisted,
  and running it independently of the process that inserted it (standing in
  for "the app restarted") still delivers the event.
  """

  use ElixirChat.DataCase
  use Oban.Testing, repo: ElixirChat.Repo

  alias ElixirChat.Accounts.Scope
  alias ElixirChat.Chat
  alias ElixirChat.Chat.Channel
  alias ElixirChat.Repo
  alias ElixirChat.Workers.PublishOutboxEvent

  test "an outbox publish job persists across a simulated restart and still delivers" do
    user = user_fixture()
    channel = channel_fixture()

    message =
      Oban.Testing.with_testing_mode(:manual, fn ->
        Chat.subscribe(channel.id)
        {:ok, message} = Chat.create_message(Scope.for_user(user), channel, %{body: "durable"})

        # Not yet delivered — in :manual mode `Oban.insert` only persists the
        # job row, it does not run it.
        refute_receive {:message_created, _}, 50

        message
      end)

    assert_enqueued(worker: PublishOutboxEvent, args: %{event_id: outbox_event_id(message)})

    # Stands in for "the app restarted": fetch and run the persisted job with
    # no reference to anything held in the process that inserted it.
    assert %{success: 1, discard: 0, failure: 0} = Oban.drain_queue(queue: :outbox)

    assert_receive {:message_created, %Chat.Message{id: message_id}}
    assert message_id == message.id
  end

  defp outbox_event_id(message) do
    "channel:#{message.channel_id}"
    |> Chat.Outbox.list_since(0)
    |> List.last()
    |> Map.fetch!(:id)
  end

  defp user_fixture do
    %ElixirChat.Accounts.User{}
    |> ElixirChat.Accounts.User.registration_changeset(%{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "long-test-password"
    })
    |> Repo.insert!()
  end

  defp channel_fixture do
    Repo.insert!(
      Channel.changeset(%Channel{}, %{
        name: "durability-#{System.unique_integer([:positive])}",
        kind: :public
      })
    )
  end
end
