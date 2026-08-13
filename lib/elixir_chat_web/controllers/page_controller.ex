defmodule ElixirChatWeb.PageController do
  use ElixirChatWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope do
      case ElixirChat.Chat.get_default_channel() do
        {:ok, channel} -> redirect(conn, to: ~p"/channels/#{channel.id}")
        {:error, :not_found} -> redirect(conn, to: ~p"/channels")
      end
    else
      redirect(conn, to: ~p"/login")
    end
  end
end
