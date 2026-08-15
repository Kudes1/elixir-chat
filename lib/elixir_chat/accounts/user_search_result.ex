defmodule ElixirChat.Accounts.UserSearchResult do
  @moduledoc "A small, source-independent user search result."

  @enforce_keys [:id, :login, :display_name, :online?]
  defstruct [:id, :login, :display_name, :online?]
end
