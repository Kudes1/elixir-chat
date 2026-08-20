defmodule ElixirChatWeb.BrowserTimeZoneTest do
  use ElixirChatWeb.ConnCase, async: true

  alias ElixirChatWeb.BrowserTimeZone

  test "stores the browser time zone from its cookie", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Test.put_req_cookie("orbit_time_zone", "Asia/Omsk")
      |> BrowserTimeZone.call([])

    assert get_session(conn, :time_zone) == "Asia/Omsk"
  end

  test "ignores an invalidly long cookie value", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Test.put_req_cookie("orbit_time_zone", String.duplicate("a", 65))
      |> BrowserTimeZone.call([])

    assert get_session(conn, :time_zone) == nil
  end
end
