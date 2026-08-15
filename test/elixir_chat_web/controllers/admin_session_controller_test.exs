defmodule ElixirChatWeb.AdminSessionControllerTest do
  use ElixirChatWeb.ConnCase

  test "an admin without a fresh sudo session is redirected to reauth when visiting /admin/users",
       %{conn: conn} do
    admin = register_user(%{login: "sudo.less.admin", role: :admin})
    conn = log_in_user(conn, admin)

    conn = get(conn, ~p"/admin/users")

    assert redirected_to(conn) == ~p"/admin/reauth"
  end

  test "an admin without sudo can still reach /admin/reauth (no redirect loop)", %{conn: conn} do
    admin = register_user(%{login: "reauth.reachable.admin", role: :admin})
    conn = log_in_user(conn, admin)

    conn = get(conn, ~p"/admin/reauth")

    assert html_response(conn, 200)
  end
end
