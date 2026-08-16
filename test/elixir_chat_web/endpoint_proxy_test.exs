defmodule ElixirChatWeb.EndpointProxyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ElixirChatWeb.Endpoint

  @rewrite_on [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]

  test "connection origin policy accepts the current origin and rejects another host" do
    matching = origin_conn("chat.example.com", "https://chat.example.com")
    mismatching = origin_conn("chat.example.com", "https://other.example.com")

    refute check_origin(matching).halted

    rejected = check_origin(mismatching)
    assert rejected.halted
    assert rejected.status == 403
  end

  test "SSL redirects preserve each forwarded public host" do
    for host <- ["chat.example.com", "team.example.net"] do
      conn =
        conn(:get, "http://phoenix.internal/somewhere")
        |> put_req_header("x-forwarded-host", host)
        |> put_req_header("x-forwarded-port", "80")
        |> put_req_header("x-forwarded-proto", "http")
        |> Plug.SSL.call(Plug.SSL.init(host: nil, rewrite_on: @rewrite_on))

      assert get_resp_header(conn, "location") == ["https://#{host}/somewhere"]
    end
  end

  defp origin_conn(host, origin) do
    conn(:get, "/live/websocket")
    |> Map.merge(%{scheme: :https, host: host, port: 443})
    |> put_req_header("origin", origin)
  end

  defp check_origin(conn) do
    Phoenix.Socket.Transport.check_origin(
      conn,
      Phoenix.LiveView.Socket,
      Endpoint,
      [check_origin: :conn],
      & &1
    )
  end
end
