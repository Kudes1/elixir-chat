defmodule ElixirChat.OnlineUsersTest do
  use ElixirChat.DataCase

  alias ElixirChat.Accounts
  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.OnlineUsers
  alias ElixirChat.Repo
  alias ElixirChatWeb.Presence

  @topic "presence:lobby"

  setup do
    OnlineUsers.subscribe_count()
    :ok
  end

  test "keeps a user until the last Presence meta leaves and searches normalized Unicode" do
    id = System.unique_integer([:positive]) + 1_000_000
    first_tab = start_supervised!({Agent, fn -> :ok end}, id: {:tab, id, 1})
    second_tab = start_supervised!({Agent, fn -> :ok end}, id: {:tab, id, 2})
    meta = %{id: id, login: "unicode.user", display_name: "Йона"}

    {:ok, _} = Presence.track(first_tab, @topic, to_string(id), meta)
    assert_receive {:online_count, _}
    {:ok, _} = Presence.track(second_tab, @topic, to_string(id), meta)
    assert_receive {:online_count, _}

    assert [%{id: ^id, online?: true}] = OnlineUsers.search("и\u0306ОН", [], 20)

    :ok = Presence.untrack(first_tab, @topic, to_string(id))
    assert_receive {:online_count, _}
    assert [%{id: ^id}] = OnlineUsers.search("unicode.user", [], 20)

    :ok = Presence.untrack(second_tab, @topic, to_string(id))
    assert_receive {:online_count, _}
    assert OnlineUsers.search("unicode.user", [], 20) == []
  end

  test "rebuilds ETS from Presence after the cache restarts" do
    id = System.unique_integer([:positive]) + 2_000_000
    tab = start_supervised!({Agent, fn -> :ok end}, id: {:restart_tab, id})

    {:ok, _} =
      Presence.track(tab, @topic, to_string(id), %{
        id: id,
        login: "restart.user",
        display_name: "Перезапуск"
      })

    assert_receive {:online_count, _}
    old_cache = Process.whereis(OnlineUsers)
    monitor = Process.monitor(old_cache)
    Process.exit(old_cache, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_cache, :killed}
    assert_receive {:online_count, _}, 1_000

    assert Process.whereis(OnlineUsers) != old_cache
    assert [%{id: ^id}] = OnlineUsers.search("restart", [], 20)
  end

  test "short messageable search stays in ETS while longer search appends database users" do
    current = user_fixture("cache.current", "Текущий")
    online = user_fixture("needle.online", "Needle Online")
    database = user_fixture("needle.database", "Needle Database")
    tab = start_supervised!({Agent, fn -> :ok end}, id: {:search_tab, online.id})

    {:ok, _} =
      Presence.track(tab, @topic, to_string(online.id), %{
        id: online.id,
        login: online.login,
        display_name: online.display_name
      })

    assert_receive {:online_count, _}
    handler_id = "online-search-query-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elixir_chat, :repo, :query],
        fn _, _, _, _ ->
          send(test_pid, :repo_query)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert [%{id: id, online?: true}] =
             Accounts.search_messageable_users(Scope.for_user(current), "ne", 20)

    assert id == online.id
    refute_receive :repo_query

    results = Accounts.search_messageable_users(Scope.for_user(current), "needle", 20)
    assert Enum.map(results, & &1.id) == [online.id, database.id]
    assert Enum.map(results, & &1.online?) == [true, false]
    assert_receive :repo_query
  end

  defp user_fixture(login, display_name) do
    %User{}
    |> User.registration_changeset(%{
      login: login,
      display_name: display_name,
      password: "long-test-password"
    })
    |> Repo.insert!()
  end
end
