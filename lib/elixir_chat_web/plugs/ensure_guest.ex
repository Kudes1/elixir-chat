defmodule ElixirChatWeb.Plugs.EnsureGuest do
  @moduledoc "Ensures every browser session has a stable guest identity."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :guest_id) do
      guest_id when is_binary(guest_id) -> conn
      _ -> put_guest(conn)
    end
  end

  defp put_guest(conn) do
    guest_id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    suffix = guest_id |> String.slice(-4, 4) |> String.upcase()

    conn
    |> put_session(:guest_id, guest_id)
    |> put_session(:visitor_name, "Гость #{suffix}")
  end
end
