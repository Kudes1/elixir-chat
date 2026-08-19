defmodule ElixirChat.Workers.BatchDeleteTest do
  use ExUnit.Case, async: true

  alias ElixirChat.Workers.BatchDelete

  test "run/1 keeps invoking the batch function until it deletes nothing" do
    {:ok, counts} = Agent.start_link(fn -> [3, 3, 2, 0] end)

    delete_batch = fn ->
      Agent.get_and_update(counts, fn
        [next | rest] -> {next, rest}
      end)
    end

    assert :ok = BatchDelete.run(delete_batch)
    assert Agent.get(counts, & &1) == []
  end

  test "run/1 stops immediately when the first batch is already empty" do
    calls = :counters.new(1, [])
    delete_batch = fn -> :counters.add(calls, 1, 1) && 0 end

    assert :ok = BatchDelete.run(delete_batch)
    assert :counters.get(calls, 1) == 1
  end
end
