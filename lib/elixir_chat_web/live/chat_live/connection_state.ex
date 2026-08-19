defmodule ElixirChatWeb.ChatLive.ConnectionState do
  @moduledoc """
  Pure DISCONNECTED -> CONNECTING -> (CATCHING_UP | LIVE) client connection
  state machine.

  This is the single source of truth for which transitions are valid.
  `assets/js/app.js`'s `CONNECTION_TRANSITIONS`/`connectionState` mirror this
  table for the client-side runtime, since "connect"/"disconnect" are only
  observable in the browser — keep both in sync when changing transitions here.
  """

  @states [:disconnected, :connecting, :catching_up, :live]

  @transitions %{
    {:disconnected, :connect} => :connecting,
    {:connecting, :connected_live} => :live,
    {:connecting, :connected_catching_up} => :catching_up,
    {:connecting, :disconnect} => :disconnected,
    {:catching_up, :caught_up} => :live,
    {:catching_up, :disconnect} => :disconnected,
    {:live, :disconnect} => :disconnected,
    {:disconnected, :disconnect} => :disconnected
  }

  def states, do: @states

  def transition(state, event) when state in @states do
    case Map.fetch(@transitions, {state, event}) do
      {:ok, next_state} -> {:ok, next_state}
      :error -> {:error, :invalid_transition}
    end
  end

  @doc """
  The state a freshly (re)connected mount resolves to from CONNECTING, given
  whether there is backlog to catch up on (`ChatLive`'s `@catching_up?`).
  """
  def initial_state(catching_up?) do
    event = if catching_up?, do: :connected_catching_up, else: :connected_live
    {:ok, state} = transition(:connecting, event)
    state
  end
end
