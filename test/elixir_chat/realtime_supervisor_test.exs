defmodule ElixirChat.RealtimeSupervisorTest do
  use ExUnit.Case, async: false

  alias ElixirChat.OnlineUsers
  alias ElixirChat.Repo
  alias ElixirChatWeb.{Endpoint, Presence}

  test "a PubSub crash replaces every downstream realtime process but not Repo" do
    before = process_snapshot()
    monitor = Process.monitor(before.pubsub)
    Process.exit(before.pubsub, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}

    after_restart =
      await_replacements(before, [:pubsub, :presence, :consumers, :online, :endpoint])

    assert after_restart.repo == before.repo
    assert Process.alive?(after_restart.endpoint)
    assert Process.alive?(after_restart.online)

    endpoint_monitor = Process.monitor(after_restart.endpoint)
    Process.exit(after_restart.endpoint, :kill)
    assert_receive {:DOWN, ^endpoint_monitor, :process, _, :killed}

    after_endpoint_restart = await_replacements(after_restart, [:endpoint])
    assert after_endpoint_restart.pubsub == after_restart.pubsub
    assert after_endpoint_restart.presence == after_restart.presence
    assert after_endpoint_restart.consumers == after_restart.consumers
    assert after_endpoint_restart.online == after_restart.online
    assert after_endpoint_restart.repo == after_restart.repo
  end

  defp process_snapshot do
    %{
      repo: Process.whereis(Repo),
      pubsub: Process.whereis(ElixirChat.PubSub),
      presence: Process.whereis(Presence),
      consumers: Process.whereis(ElixirChat.RealtimeConsumersSupervisor),
      online: Process.whereis(OnlineUsers),
      endpoint: Process.whereis(Endpoint)
    }
  end

  defp await_replacements(before, keys, attempts \\ 100)

  defp await_replacements(_before, _keys, 0),
    do: flunk("realtime supervision tree did not recover")

  defp await_replacements(before, keys, attempts) do
    current = process_snapshot()

    if Enum.all?(keys, fn key -> current[key] && current[key] != before[key] end) do
      current
    else
      receive do
      after
        10 -> await_replacements(before, keys, attempts - 1)
      end
    end
  end
end
