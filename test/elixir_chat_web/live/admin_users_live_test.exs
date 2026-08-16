defmodule ElixirChatWeb.AdminUsersLiveTest do
  use ElixirChatWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    admin = register_user(%{login: "admin.invites", role: :admin})

    conn =
      conn
      |> log_in_user(admin)
      |> put_session(:sudo_at, System.system_time(:second))

    %{conn: conn, admin: admin}
  end

  test "registration invitation is shown as a valid host-independent path", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view
    |> form("#invite-user-form",
      invite: %{login: "invited.person", display_name: "Invited Person"}
    )
    |> render_submit()

    path = invitation_path(view)
    assert_host_independent_path(path)

    capture_conn = get(build_conn(), path)
    assert redirected_to(capture_conn) == ~p"/invitation"
  end

  test "password reset is shown as a valid host-independent path", %{conn: conn} do
    user = register_user(%{login: "reset.person"})
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    view |> element("#reset-#{user.id}") |> render_click()

    path = invitation_path(view)
    assert_host_independent_path(path)

    capture_conn = get(build_conn(), path)
    assert redirected_to(capture_conn) == ~p"/invitation"
  end

  defp invitation_path(view) do
    [path] =
      view
      |> element("#one-time-link")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> then(&Regex.run(~r{/invitation/[A-Za-z0-9_-]+}, &1))

    path
  end

  defp assert_host_independent_path(path) do
    assert String.starts_with?(path, "/invitation/")
    refute URI.parse(path).scheme
    refute URI.parse(path).host
  end
end
