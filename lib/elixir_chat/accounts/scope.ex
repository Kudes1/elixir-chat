defmodule ElixirChat.Accounts.Scope do
  defstruct user: nil
  def for_user(%ElixirChat.Accounts.User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
