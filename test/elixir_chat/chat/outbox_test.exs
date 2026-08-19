defmodule ElixirChat.Chat.OutboxTest do
  use ElixirChat.DataCase

  alias ElixirChat.Chat.{Outbox, OutboxEvent}
  alias ElixirChat.Repo

  test "list_since/3 returns only events for the partition, strictly after the cursor, in order" do
    other_partition = insert_event!("channel:other")
    first = insert_event!("channel:a")
    second = insert_event!("channel:a")
    third = insert_event!("channel:a")

    assert Enum.map(Outbox.list_since("channel:a", 0), & &1.id) ==
             [first.id, second.id, third.id]

    assert Enum.map(Outbox.list_since("channel:a", first.id), & &1.id) ==
             [second.id, third.id]

    assert Outbox.list_since("channel:a", third.id) == []
    refute other_partition.id in Enum.map(Outbox.list_since("channel:a", 0), & &1.id)
  end

  test "list_since/3 paginates a large backlog without gaps or duplicates" do
    events = for _ <- 1..25, do: insert_event!("channel:backlog")
    expected_ids = Enum.map(events, & &1.id)

    {collected, _final_cursor} =
      Enum.reduce_while(1..100, {[], 0}, fn _iteration, {acc, cursor} ->
        case Outbox.list_since("channel:backlog", cursor, 7) do
          [] -> {:halt, {acc, cursor}}
          batch -> {:cont, {acc ++ batch, List.last(batch).id}}
        end
      end)

    assert Enum.map(collected, & &1.id) == expected_ids
  end

  test "list_events_since/2 returns [] for an empty cursor map without querying" do
    insert_event!("channel:untouched")
    assert Outbox.list_events_since(%{}) == []
  end

  test "list_events_since/2 merges multiple partitions, each resumed from its own cursor" do
    a1 = insert_event!("channel:a")
    b1 = insert_event!("channel:b")
    a2 = insert_event!("channel:a")
    b2 = insert_event!("channel:b")
    ignored = insert_event!("channel:c")

    cursors = %{"channel:a" => a1.id, "channel:b" => 0}

    ids = Outbox.list_events_since(cursors) |> Enum.map(& &1.id)

    assert ids == Enum.sort([a2.id, b1.id, b2.id])
    refute ignored.id in ids
  end

  test "list_events_since/2 respects the batch limit so large backlogs are drained incrementally" do
    for _ <- 1..10, do: insert_event!("channel:limited")

    assert length(Outbox.list_events_since(%{"channel:limited" => 0}, limit: 4)) == 4
  end

  test "concurrent inserts across partitions are uniquely and monotonically ordered" do
    test_pid = self()
    partitions = for i <- 1..5, do: "channel:concurrent-#{i}"

    tasks =
      for i <- 1..100 do
        Task.async(fn ->
          receive do
            :go -> :ok
          end

          insert_event!(Enum.at(partitions, rem(i, length(partitions))))
        end)
      end

    Enum.each(tasks, fn %Task{pid: pid} ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, pid)
      send(pid, :go)
    end)

    events = Task.await_many(tasks, 5_000)

    ids = Enum.map(events, & &1.id)
    assert length(Enum.uniq(ids)) == length(ids)

    events
    |> Enum.group_by(& &1.partition_key)
    |> Enum.each(fn {partition_key, group} ->
      stored_ids = partition_key |> Outbox.list_since(0, 1_000) |> Enum.map(& &1.id)
      expected_ids = group |> Enum.map(& &1.id) |> Enum.sort()
      assert stored_ids == expected_ids
    end)
  end

  test "delete_published_before/2 deletes only published events older than the cutoff" do
    cutoff = DateTime.utc_now()

    old_published = insert_event!("channel:a") |> publish_at!(DateTime.add(cutoff, -3600))
    recent_published = insert_event!("channel:a") |> publish_at!(DateTime.add(cutoff, 3600))
    old_unpublished = insert_event!("channel:a")

    assert Outbox.delete_published_before(cutoff) == 1
    refute Repo.get(OutboxEvent, old_published.id)
    assert Repo.get(OutboxEvent, recent_published.id)
    assert Repo.get(OutboxEvent, old_unpublished.id)
  end

  test "delete_published_before/2 batches so a large backlog is deleted in bounded chunks" do
    cutoff = DateTime.utc_now()

    events =
      for _ <- 1..25 do
        insert_event!("channel:cleanup-batch") |> publish_at!(DateTime.add(cutoff, -3600))
      end

    assert Outbox.delete_published_before(cutoff, 10) == 10
    assert Outbox.delete_published_before(cutoff, 10) == 10
    assert Outbox.delete_published_before(cutoff, 10) == 5
    assert Outbox.delete_published_before(cutoff, 10) == 0

    Enum.each(events, fn event -> refute Repo.get(OutboxEvent, event.id) end)
  end

  defp publish_at!(event, published_at) do
    event |> Ecto.Changeset.change(published_at: published_at) |> Repo.update!()
  end

  defp insert_event!(partition_key) do
    Repo.insert!(
      OutboxEvent.changeset(%OutboxEvent{}, %{
        event_id: Ecto.UUID.generate(),
        event_type: "message_created",
        partition_key: partition_key,
        payload: %{"version" => 1},
        available_at: DateTime.utc_now()
      })
    )
  end
end
