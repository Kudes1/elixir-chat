defmodule ElixirChat.OutboxDispatcherTest do
  use ElixirChat.DataCase

  alias ElixirChat.Chat.OutboxEvent
  alias ElixirChat.OutboxDispatcher
  alias ElixirChat.Repo

  test "failed publications remain pending and can be retried" do
    event = event_fixture("channel:retry")
    test_pid = self()

    publisher = fn published_event ->
      send(test_pid, {:publication_attempt, published_event.id})

      if Process.get(:publisher_succeeds, false) do
        :ok
      else
        Process.put(:publisher_succeeds, true)
        {:error, :temporary}
      end
    end

    name = unique_name(:retry_dispatcher)

    pid =
      start_supervised!({OutboxDispatcher, name: name, publisher: publisher, interval: 60_000})

    allow_process(pid)

    assert {:ok, 1} = OutboxDispatcher.dispatch_now(name)
    assert_receive {:publication_attempt, event_id}
    assert event_id == event.id

    failed = Repo.get!(OutboxEvent, event.id)
    assert failed.attempt_count == 1
    assert is_nil(failed.published_at)
    assert failed.last_error =~ "temporary"

    failed
    |> Ecto.Changeset.change(available_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, 1} = OutboxDispatcher.dispatch_now(name)
    assert_receive {:publication_attempt, ^event_id}
    assert Repo.get!(OutboxEvent, event.id).published_at
  end

  test "a failed event blocks its channel but not another channel" do
    first = event_fixture("channel:blocked")
    second = event_fixture("channel:blocked")
    independent = event_fixture("channel:independent")
    test_pid = self()

    publisher = fn event ->
      send(test_pid, {:published, event.id})
      if event.id == first.id, do: {:error, :blocked}, else: :ok
    end

    name = unique_name(:ordering_dispatcher)

    pid =
      start_supervised!({OutboxDispatcher, name: name, publisher: publisher, interval: 60_000})

    allow_process(pid)

    assert {:ok, 2} = OutboxDispatcher.dispatch_now(name)
    assert_receive {:published, first_id}
    assert first_id == first.id
    assert_receive {:published, independent_id}
    assert independent_id == independent.id
    second_id = second.id
    refute_receive {:published, ^second_id}

    refute Repo.get!(OutboxEvent, first.id).published_at
    refute Repo.get!(OutboxEvent, second.id).published_at
    assert Repo.get!(OutboxEvent, independent.id).published_at
  end

  defp event_fixture(partition_key) do
    now = DateTime.utc_now()

    Repo.insert!(
      OutboxEvent.changeset(%OutboxEvent{}, %{
        event_id: Ecto.UUID.generate(),
        event_type: "message_created",
        partition_key: partition_key,
        payload: %{"version" => 1},
        available_at: now
      })
    )
  end

  defp allow_process(pid) do
    Ecto.Adapters.SQL.Sandbox.allow(ElixirChat.Repo, self(), pid)
  end

  defp unique_name(prefix),
    do: {:global, {prefix, System.unique_integer([:positive])}}
end
