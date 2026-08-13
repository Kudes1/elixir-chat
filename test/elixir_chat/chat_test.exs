defmodule ElixirChat.ChatTest do
  use ElixirChat.DataCase

  alias ElixirChat.Chat
  alias ElixirChat.Chat.{Channel, Message}
  alias ElixirChat.Repo

  setup do
    user =
      %ElixirChat.Accounts.User{}
      |> ElixirChat.Accounts.User.registration_changeset(%{
        login: "user#{System.unique_integer([:positive])}",
        display_name: "Ирина",
        password: "long-test-password"
      })
      |> Repo.insert!()

    %{scope: ElixirChat.Accounts.Scope.for_user(user)}
  end

  test "only public channels are visible and general is the default" do
    other = channel_fixture(%{name: "alpha"})
    general = channel_fixture(%{name: "general"})
    private = channel_fixture(%{name: "secret", kind: :private})

    assert Enum.map(Chat.list_channels(), & &1.id) == [other.id, general.id]
    assert {:ok, ^general} = Chat.get_default_channel()
    assert {:error, :not_found} = Chat.get_channel("not-an-id")
    assert {:error, :not_found} = Chat.get_channel(private.id)
  end

  test "message input is normalized and authorship cannot be overridden", %{scope: scope} do
    channel = channel_fixture(%{name: "general"})
    other = channel_fixture(%{name: "other"})

    assert {:ok, message} =
             Chat.create_message(scope, channel, %{
               author_name: "Подмена",
               body: "  привет  ",
               channel_id: other.id
             })

    assert message.author_name == "Ирина"
    assert message.body == "привет"
    assert message.channel_id == channel.id

    assert {:error, changeset} =
             Chat.create_message(scope, channel, %{author_name: "Подмена", body: "   "})

    assert "can't be blank" in errors_on(changeset).body
  end

  test "cursor pagination has no gaps or duplicates", %{scope: scope} do
    channel = channel_fixture(%{name: "general"})

    messages =
      for number <- 1..55 do
        message_fixture(scope, channel, %{body: "message #{number}"})
      end

    {recent, true} = Chat.list_recent_messages(channel.id)
    {older, false} = Chat.list_messages_before(channel.id, List.first(recent))

    assert length(recent) == 50
    assert length(older) == 5
    assert Enum.map(older ++ recent, & &1.id) == Enum.map(messages, & &1.id)
  end

  test "seeds are idempotent" do
    Code.eval_file("priv/repo/seeds.exs")
    Code.eval_file("priv/repo/seeds.exs")

    assert Repo.aggregate(Channel, :count) == 3
    assert Repo.aggregate(Message, :count) == 2
  end

  defp channel_fixture(attrs) do
    defaults = %{name: "channel-#{System.unique_integer([:positive])}", kind: :public}
    Repo.insert!(Channel.changeset(%Channel{}, Map.merge(defaults, attrs)))
  end

  defp message_fixture(scope, channel, attrs) do
    defaults = %{author_name: "Ирина", body: "message"}
    {:ok, message} = Chat.create_message(scope, channel, Map.merge(defaults, attrs))
    message
  end
end
