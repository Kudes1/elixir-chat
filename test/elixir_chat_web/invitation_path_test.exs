defmodule ElixirChatWeb.InvitationPathTest do
  use ExUnit.Case, async: true

  alias ElixirChatWeb.InvitationPath

  test "builds a route-verified host-independent path" do
    path = InvitationPath.for_token("abc_123-XYZ")

    assert path == "/invitation/abc_123-XYZ"
    refute URI.parse(path).scheme
    refute URI.parse(path).host
  end
end
