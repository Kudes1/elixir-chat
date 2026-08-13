defmodule ElixirChatWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ElixirChatWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ElixirChatWeb.Endpoint

      use ElixirChatWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ElixirChatWeb.ConnCase
    end
  end

  def register_user(attrs \\ %{}) do
    defaults = %{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "long-test-password"
    }

    %ElixirChat.Accounts.User{}
    |> ElixirChat.Accounts.User.registration_changeset(
      Map.merge(defaults, attrs),
      Map.get(attrs, :role, :user)
    )
    |> ElixirChat.Repo.insert!()
  end

  def log_in_user(conn, user) do
    token = ElixirChat.Accounts.generate_session_token(user)

    Plug.Test.init_test_session(conn, %{
      user_token: token,
      live_socket_id: "users_sessions:#{user.id}"
    })
  end

  setup tags do
    ElixirChat.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
