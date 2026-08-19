defmodule ElixirChat.Chat.MentionsTest do
  use ExUnit.Case, async: true

  alias ElixirChat.Chat.Mentions

  test "logins/1 extracts logins without the leading @" do
    assert Mentions.logins("привет @alice, как дела?") == ["alice"]
  end

  test "logins/1 collects every distinct mention in a message, in first-seen order" do
    assert Mentions.logins("@bob @alice спасибо, @bob") == ["bob", "alice"]
  end

  test "logins/1 returns an empty list for a message with no mentions" do
    assert Mentions.logins("обычное сообщение без адресата") == []
  end

  test "logins/1 does not require the login to actually exist — resolution happens elsewhere" do
    assert Mentions.logins("@no.such.user привет") == ["no.such.user"]
  end

  test "fragments/1 splits text and mention parts in order for rendering" do
    assert Mentions.fragments("привет @alice!") == [
             {:text, "привет "},
             {:mention, "@alice"},
             {:text, "!"}
           ]
  end

  test "fragments/1 returns the whole body as text when there is no mention" do
    assert Mentions.fragments("просто текст") == [{:text, "просто текст"}]
  end
end
