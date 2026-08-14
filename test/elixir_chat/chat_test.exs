defmodule ElixirChat.ChatTest do
  use ElixirChat.DataCase

  alias ElixirChat.Chat
  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat.{Channel, ChannelMembership, DirectConversation, Message}
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

    %{scope: Scope.for_user(user), user: user}
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

  test "channels receive unique UUIDv4 public identifiers" do
    first = channel_fixture(%{name: "first-public-id"})
    second = channel_fixture(%{name: "second-public-id"})

    assert {:ok, first_public_id} = Ecto.UUID.cast(first.public_id)
    assert first_public_id == first.public_id
    assert String.at(first.public_id, 14) == "4"
    refute first.public_id == second.public_id
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

    {newer, false} = Chat.list_messages_after(channel.id, List.last(older))
    assert Enum.map(newer, & &1.id) == Enum.map(Enum.drop(messages, 5), & &1.id)
  end

  test "direct conversation creation is idempotent and private", %{scope: scope, user: user} do
    other_user = user_fixture(%{login: "other.user", display_name: "Другой"})
    outsider = user_fixture(%{login: "outsider", display_name: "Посторонний"})

    assert {:ok, first} = Chat.get_or_create_direct_conversation(scope, other_user.id)
    assert {:ok, second} = Chat.get_or_create_direct_conversation(scope, other_user.id)
    assert first.id == second.id
    assert first.channel.kind == :private
    assert DirectConversation.other_user(first, user.id).id == other_user.id

    assert Enum.map(Chat.list_direct_conversations(scope), & &1.id) == [first.id]

    assert Enum.map(Chat.list_direct_conversations(Scope.for_user(other_user)), & &1.id) == [
             first.id
           ]

    assert Chat.list_direct_conversations(Scope.for_user(outsider)) == []
    assert {:error, :not_found} = Chat.get_direct_conversation(Scope.for_user(outsider), first.id)

    assert {:ok, public_direct} =
             Chat.get_direct_conversation_by_public_id(scope, first.channel.public_id)

    assert public_direct.id == first.id

    assert {:ok, _public_direct} =
             Chat.get_direct_conversation_by_public_id(
               Scope.for_user(other_user),
               first.channel.public_id
             )

    assert {:error, :not_found} =
             Chat.get_direct_conversation_by_public_id(
               Scope.for_user(outsider),
               first.channel.public_id
             )

    assert {:error, :not_found} =
             Chat.get_direct_conversation_by_public_id(scope, Integer.to_string(first.id))

    assert {:error, :not_found} = Chat.get_channel(first.channel.id)
    assert {:ok, {[], false}} = Chat.list_recent_messages(scope, first.channel.id)

    assert {:error, :not_found} =
             Chat.list_recent_messages(Scope.for_user(outsider), first.channel.id)

    refute Repo.exists?(
             from membership in ChannelMembership,
               where: membership.channel_id == ^first.channel.id
           )

    assert {:error, :not_found} = Chat.get_or_create_direct_conversation(scope, user.id)
  end

  test "direct messages enforce membership and disabled-recipient rules", %{scope: scope} do
    other_user = user_fixture(%{login: "recipient", display_name: "Получатель"})
    outsider = user_fixture(%{login: "outsider", display_name: "Посторонний"})
    assert {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other_user.id)

    assert {:error, :forbidden} =
             Chat.create_message(Scope.for_user(outsider), direct.channel, %{body: "Секрет"})

    assert {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "Привет"})
    assert message.channel_id == direct.channel.id

    other_user
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:error, :recipient_disabled} =
             Chat.create_message(scope, direct.channel, %{body: "Ты здесь?"})
  end

  test "direct conversations are ordered by latest message activity", %{scope: scope} do
    first_user = user_fixture(%{login: "first", display_name: "Первый"})
    second_user = user_fixture(%{login: "second", display_name: "Второй"})
    assert {:ok, first} = Chat.get_or_create_direct_conversation(scope, first_user.id)
    assert {:ok, second} = Chat.get_or_create_direct_conversation(scope, second_user.id)
    assert Enum.map(Chat.list_direct_conversations(scope), & &1.id) == [second.id, first.id]

    assert {:ok, _message} = Chat.create_message(scope, first.channel, %{body: "Поднять наверх"})
    conversations = Chat.list_direct_conversations(scope)
    assert Enum.map(conversations, & &1.id) == [first.id, second.id]
  end

  test "seeds are idempotent" do
    Code.eval_file("priv/repo/seeds.exs")
    Code.eval_file("priv/repo/seeds.exs")

    assert Repo.aggregate(Channel, :count) == 3
    assert Repo.aggregate(Message, :count) == 2
  end

  test "group channels enforce membership, ownership, transfer and soft archival", %{
    scope: owner_scope,
    user: owner
  } do
    member = user_fixture(%{login: "private.member", display_name: "Участник"})
    outsider = user_fixture(%{login: "private.outsider", display_name: "Посторонний"})
    member_scope = Scope.for_user(member)
    outsider_scope = Scope.for_user(outsider)

    assert {:ok, channel} =
             Chat.create_channel(owner_scope, %{
               name: "private-team",
               description: "Закрытая команда",
               kind: :private
             })

    assert channel.owner_id == owner.id
    assert {:ok, [_owner_membership]} = Chat.list_channel_memberships(owner_scope, channel)
    assert {:ok, public_channel} = Chat.get_channel_by_public_id(owner_scope, channel.public_id)
    assert public_channel.id == channel.id
    assert {:error, :not_found} = Chat.get_channel_by_public_id(outsider_scope, channel.public_id)
    assert {:error, :not_found} = Chat.get_channel_by_public_id(owner_scope, "not-a-uuid")

    assert {:error, :not_found} =
             Chat.get_channel_by_public_id(owner_scope, to_string(channel.id))

    assert {:error, :not_found} = Chat.get_channel(outsider_scope, channel.id)
    assert {:error, :not_found} = Chat.list_messages(outsider_scope, channel.id)
    assert {:error, :forbidden} = Chat.create_message(outsider_scope, channel, %{body: "Нет"})

    assert {:ok, ^channel} = Chat.invite_member(owner_scope, channel, member)
    assert {:ok, invited_channel} = Chat.get_channel(member_scope, channel.id)
    assert invited_channel.id == channel.id

    assert {:ok, message} = Chat.create_message(member_scope, invited_channel, %{body: "История"})
    assert {:error, :owner_must_transfer} = Chat.leave_channel(owner_scope, channel)
    assert {:ok, transferred} = Chat.transfer_ownership(owner_scope, channel, member)
    assert transferred.owner_id == member.id
    assert {:ok, _} = Chat.leave_channel(owner_scope, transferred)
    assert {:error, :not_found} = Chat.get_channel(owner_scope, channel.id)

    assert {:ok, archived} = Chat.archive_channel(member_scope, transferred)
    assert archived.archived_at
    assert {:error, :not_found} = Chat.get_channel(member_scope, channel.id)
    assert {:error, :not_found} = Chat.list_messages(member_scope, channel.id)
    assert Enum.map(Chat.list_messages(channel.id), & &1.id) == [message.id]

    assert Repo.exists?(
             from membership in ChannelMembership, where: membership.channel_id == ^channel.id
           )
  end

  test "public catalog supports joining and leaving without exposing history", %{
    scope: owner_scope
  } do
    visitor = user_fixture(%{login: "catalog.visitor", display_name: "Посетитель"})
    visitor_scope = Scope.for_user(visitor)

    assert {:ok, channel} =
             Chat.create_channel(owner_scope, %{
               name: "public-catalog",
               description: "Виден до вступления",
               kind: :public
             })

    assert [%{id: id, name: "public-catalog", description: "Виден до вступления"}] =
             Chat.list_available_public_channels(visitor_scope)

    assert id == channel.id
    assert {:error, :not_found} = Chat.get_channel(visitor_scope, channel.id)
    assert {:error, :not_found} = Chat.list_recent_messages(visitor_scope, channel.id)
    assert {:ok, joined} = Chat.join_channel(visitor_scope, channel.id)
    assert {:ok, _} = Chat.get_channel(visitor_scope, joined.id)
    assert Chat.list_available_public_channels(visitor_scope) == []
    assert {:ok, _} = Chat.leave_channel(visitor_scope, joined)
    assert {:error, :not_found} = Chat.get_channel(visitor_scope, joined.id)
  end

  test "private members may invite while only the owner may remove", %{scope: owner_scope} do
    member = user_fixture(%{login: "invite.member", display_name: "Участник"})
    invited = user_fixture(%{login: "invite.target", display_name: "Приглашённый"})
    member_scope = Scope.for_user(member)

    assert {:ok, channel} =
             Chat.create_channel(owner_scope, %{name: "invite-room", kind: :private})

    assert {:ok, _} = Chat.invite_member(owner_scope, channel, member)
    assert [^invited] = Chat.search_invitable_users(member_scope, channel, "target")
    assert {:ok, _} = Chat.invite_member(member_scope, channel, invited)
    assert {:error, :forbidden} = Chat.remove_member(member_scope, channel, invited)
    assert {:ok, _} = Chat.remove_member(owner_scope, channel, invited)
    assert {:error, :not_found} = Chat.get_channel(Scope.for_user(invited), channel.id)
  end

  test "general cannot be left, privatized, renamed or archived", %{scope: scope, user: user} do
    general =
      %Channel{owner_id: user.id, is_general: true}
      |> Channel.changeset(%{name: "general", kind: :public, purpose: :group})
      |> Repo.insert!()

    Repo.insert!(
      ChannelMembership.changeset(%ChannelMembership{}, %{
        channel_id: general.id,
        user_id: user.id
      })
    )

    assert {:error, :protected_channel} = Chat.leave_channel(scope, general)
    assert {:error, :protected_channel} = Chat.update_channel(scope, general, %{name: "renamed"})
    assert {:error, :protected_channel} = Chat.update_channel(scope, general, %{kind: :private})
    assert {:error, :protected_channel} = Chat.archive_channel(scope, general)
    assert {:ok, updated} = Chat.update_channel(scope, general, %{description: "Новое описание"})
    assert updated.description == "Новое описание"
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

  defp user_fixture(attrs) do
    defaults = %{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "long-test-password"
    }

    %User{}
    |> User.registration_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
