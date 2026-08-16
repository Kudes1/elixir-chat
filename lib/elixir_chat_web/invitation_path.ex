defmodule ElixirChatWeb.InvitationPath do
  @moduledoc "Builds host-independent invitation paths for UI and administrative commands."

  use ElixirChatWeb, :verified_routes

  def for_token(token), do: ~p"/invitation/#{token}"
end
