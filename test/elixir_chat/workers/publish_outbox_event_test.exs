defmodule ElixirChat.Workers.PublishOutboxEventTest do
  use ElixirChat.DataCase
  use Oban.Testing, repo: ElixirChat.Repo

  alias ElixirChat.Chat.OutboxEvent
  alias ElixirChat.Repo
  alias ElixirChat.Workers.PublishOutboxEvent

  setup do
    previous = Application.get_env(:elixir_chat, PublishOutboxEvent, [])
    on_exit(fn -> Application.put_env(:elixir_chat, PublishOutboxEvent, previous) end)
    :ok
  end

  test "publishes an event through the configured publisher and marks it published" do
    event = event_fixture("channel:1")
    test_pid = self()
    stub_publisher(fn published -> send(test_pid, {:published, published.id}) && :ok end)

    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => event.id})

    assert_receive {:published, id}
    assert id == event.id
    assert Repo.get!(OutboxEvent, event.id).published_at
  end

  test "an already-published event is a no-op — safe to run the same job twice" do
    event = event_fixture("channel:1")
    stub_publisher(fn _event -> :ok end)
    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => event.id})

    test_pid = self()
    stub_publisher(fn published -> send(test_pid, {:published_again, published.id}) && :ok end)
    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => event.id})

    refute_receive {:published_again, _}
  end

  test "a deleted event (already published and retention-cleaned) is a no-op" do
    stub_publisher(fn _event -> :ok end)
    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => -1})
  end

  test "an earlier unpublished event in the same partition snoozes the later one instead of publishing out of order" do
    first = event_fixture("channel:ordering")
    second = event_fixture("channel:ordering")
    stub_publisher(fn _event -> :ok end)

    assert {:snooze, _seconds} = perform_job(PublishOutboxEvent, %{"event_id" => second.id})
    refute Repo.get!(OutboxEvent, second.id).published_at

    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => first.id})
    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => second.id})
    assert Repo.get!(OutboxEvent, second.id).published_at
  end

  test "a failed event blocks its own partition but not an independent one" do
    first = event_fixture("channel:blocked")
    independent = event_fixture("channel:independent")
    test_pid = self()

    stub_publisher(fn event ->
      send(test_pid, {:published, event.id})
      if event.id == first.id, do: raise("boom"), else: :ok
    end)

    assert {:error, _reason} = perform_job(PublishOutboxEvent, %{"event_id" => first.id})
    assert_receive {:published, first_id}
    assert first_id == first.id
    refute Repo.get!(OutboxEvent, first.id).published_at

    assert :ok = perform_job(PublishOutboxEvent, %{"event_id" => independent.id})
    assert_receive {:published, independent_id}
    assert independent_id == independent.id
    assert Repo.get!(OutboxEvent, independent.id).published_at
  end

  test "past the 10th attempt it keeps retrying (never discards) and emits one telemetry warning" do
    event = event_fixture("channel:exhausted")
    stub_publisher(fn _event -> raise "still broken" end)

    test_pid = self()

    :telemetry.attach(
      "test-outbox-retry-exhausted",
      [:elixir_chat, :outbox, :retry_exhausted],
      fn _event, measurements, meta, _config ->
        send(test_pid, {:retry_exhausted, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-outbox-retry-exhausted") end)

    assert {:error, _reason} =
             perform_job(PublishOutboxEvent, %{"event_id" => event.id}, attempt: 9)

    refute_receive {:retry_exhausted, _, _}

    assert {:error, _reason} =
             perform_job(PublishOutboxEvent, %{"event_id" => event.id}, attempt: 10)

    assert_receive {:retry_exhausted, %{attempt_count: 10}, %{event_id: event_id}}
    assert event_id == event.event_id
    refute Repo.get!(OutboxEvent, event.id).published_at
  end

  defp stub_publisher(fun) do
    Application.put_env(:elixir_chat, PublishOutboxEvent, publisher: fun)
  end

  defp event_fixture(partition_key) do
    Repo.insert!(
      OutboxEvent.changeset(%OutboxEvent{}, %{
        event_id: Ecto.UUID.generate(),
        event_type: "message_created",
        partition_key: partition_key,
        payload: %{"version" => 1}
      })
    )
  end
end
