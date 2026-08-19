defmodule ElixirChat.Workers.BatchDelete do
  @moduledoc """
  Repeatedly invokes a single-batch delete function until it deletes nothing,
  so a cleanup job never holds one lock across an unbounded number of rows —
  each call is its own small, fast transaction instead.
  """

  def run(delete_batch_fun) when is_function(delete_batch_fun, 0) do
    case delete_batch_fun.() do
      0 -> :ok
      _count -> run(delete_batch_fun)
    end
  end
end
