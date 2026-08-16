defmodule ElixirChatWeb.ChatLive.MessageTimeTest do
  use ExUnit.Case, async: true

  alias ElixirChatWeb.ChatLive.MessageTime

  test "omits the current year and includes a different year in date labels" do
    assert MessageTime.date_label(~D[2026-08-16], 2026) == "16 августа"
    assert MessageTime.date_label(~D[2025-08-16], 2026) == "16 августа 2025"
  end

  test "localizes UTC timestamps with daylight-saving rules" do
    winter = MessageTime.localize(~U[2026-01-15 12:00:00Z], "America/New_York")
    summer = MessageTime.localize(~U[2026-07-15 12:00:00Z], "America/New_York")

    assert winter.utc_offset + winter.std_offset == -18_000
    assert summer.utc_offset + summer.std_offset == -14_400
  end
end
