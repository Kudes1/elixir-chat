defmodule ElixirChatWeb.ChatLive.ConnectionStateTest do
  use ExUnit.Case, async: true

  alias ElixirChatWeb.ChatLive.ConnectionState

  describe "transition/2" do
    test "valid transitions" do
      assert ConnectionState.transition(:disconnected, :connect) == {:ok, :connecting}
      assert ConnectionState.transition(:connecting, :connected_live) == {:ok, :live}

      assert ConnectionState.transition(:connecting, :connected_catching_up) ==
               {:ok, :catching_up}

      assert ConnectionState.transition(:connecting, :disconnect) == {:ok, :disconnected}
      assert ConnectionState.transition(:catching_up, :caught_up) == {:ok, :live}
      assert ConnectionState.transition(:catching_up, :disconnect) == {:ok, :disconnected}
      assert ConnectionState.transition(:live, :disconnect) == {:ok, :disconnected}
      assert ConnectionState.transition(:disconnected, :disconnect) == {:ok, :disconnected}
    end

    test "cannot skip DISCONNECTED/CONNECTING directly from LIVE to CATCHING_UP" do
      assert ConnectionState.transition(:live, :connected_catching_up) ==
               {:error, :invalid_transition}

      assert ConnectionState.transition(:live, :connect) == {:error, :invalid_transition}
      assert ConnectionState.transition(:live, :caught_up) == {:error, :invalid_transition}
    end

    test "rejects every other unlisted transition" do
      for state <- ConnectionState.states(),
          event <- [:connect, :connected_live, :connected_catching_up, :caught_up, :disconnect],
          not valid?(state, event) do
        assert ConnectionState.transition(state, event) == {:error, :invalid_transition}
      end
    end

    defp valid?(state, event) do
      match?({:ok, _}, ConnectionState.transition(state, event))
    end
  end

  describe "initial_state/1" do
    test "resolves CONNECTING to CATCHING_UP when there is backlog" do
      assert ConnectionState.initial_state(true) == :catching_up
    end

    test "resolves CONNECTING to LIVE when there is no backlog" do
      assert ConnectionState.initial_state(false) == :live
    end
  end

  test "control scenario: LIVE -> network lost -> DISCONNECTED -> restored -> CONNECTING -> CATCHING_UP -> LIVE" do
    events = [:disconnect, :connect, :connected_catching_up, :caught_up]

    {:ok, states} =
      Enum.reduce(events, {:ok, [:live]}, fn
        event, {:ok, [current | _] = acc} ->
          case ConnectionState.transition(current, event) do
            {:ok, next} -> {:ok, [next | acc]}
            error -> error
          end

        _event, error ->
          error
      end)

    assert Enum.reverse(states) == [:live, :disconnected, :connecting, :catching_up, :live]
  end
end
