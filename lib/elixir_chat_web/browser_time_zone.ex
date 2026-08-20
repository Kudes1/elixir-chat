defmodule ElixirChatWeb.BrowserTimeZone do
  @moduledoc false

  import Plug.Conn

  @cookie_name "orbit_time_zone"

  def init(opts), do: opts

  def call(conn, _opts) do
    case fetch_cookies(conn).req_cookies[@cookie_name] do
      time_zone when is_binary(time_zone) and byte_size(time_zone) <= 64 ->
        if get_session(conn, :time_zone) == time_zone,
          do: conn,
          else: put_session(conn, :time_zone, time_zone)

      _other ->
        conn
    end
  end
end
