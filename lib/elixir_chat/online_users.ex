defmodule ElixirChat.OnlineUsers do
  @moduledoc "A node-local ETS projection of the cluster-wide chat Presence state."

  use GenServer

  alias ElixirChat.Accounts.UserSearchResult
  alias ElixirChatWeb.Presence

  @table __MODULE__
  @presence_topic "presence:lobby"
  @updates_topic "online_users:updates"
  @count_topic "online_users:count"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def count do
    case :ets.whereis(@table) do
      :undefined -> 0
      _table -> :ets.info(@table, :size)
    end
  end

  def subscribe_count,
    do: Phoenix.PubSub.subscribe(ElixirChat.PubSub, @count_topic)

  def search(query, excluded_ids \\ [], limit \\ 20)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    normalized_query = normalize(query)
    excluded = MapSet.new(excluded_ids)

    rows =
      case :ets.whereis(@table) do
        :undefined -> []
        _table -> :ets.tab2list(@table)
      end

    rows
    |> Enum.reject(fn {id, _, _, _, _} -> MapSet.member?(excluded, id) end)
    |> Enum.filter(fn {_id, _login, _name, login_search, name_search} ->
      normalized_query == "" or String.contains?(login_search, normalized_query) or
        String.contains?(name_search, normalized_query)
    end)
    |> Enum.sort_by(fn {id, login, name, login_search, name_search} ->
      {name_search, login_search, name, login, id}
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {id, login, display_name, _, _} ->
      %UserSearchResult{id: id, login: login, display_name: display_name, online?: true}
    end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true,
      write_concurrency: false
    ])

    Phoenix.PubSub.subscribe(ElixirChat.PubSub, @updates_topic)
    send(self(), :rebuild)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:rebuild, state) do
    Presence.list(@presence_topic)
    |> Enum.each(fn {key, %{metas: metas}} -> replace_user(key, metas) end)

    broadcast_count()
    {:noreply, state}
  end

  def handle_info({Presence, {:metas, key, metas}}, state) do
    replace_user(key, metas)
    broadcast_count()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  def updates_topic, do: @updates_topic

  defp replace_user(key, []) do
    with {:ok, id} <- parse_id(key), do: :ets.delete(@table, id)
  end

  defp replace_user(key, metas) do
    with {:ok, id} <- parse_id(key),
         meta when is_map(meta) <- List.first(metas),
         login when is_binary(login) <- meta[:login] || meta["login"],
         display_name when is_binary(display_name) <-
           meta[:display_name] || meta["display_name"] do
      :ets.insert(
        @table,
        {id, login, display_name, normalize(login), normalize(display_name)}
      )
    else
      _ -> :ok
    end
  end

  defp broadcast_count do
    Phoenix.PubSub.local_broadcast(
      ElixirChat.PubSub,
      @count_topic,
      {:online_count, count()}
    )
  end

  defp normalize(value) do
    value
    |> String.trim()
    |> :unicode.characters_to_nfc_binary()
    |> String.downcase()
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error
end
