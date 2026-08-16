defmodule ElixirChat.ChatTest do
  use ElixirChat.DataCase

  alias ElixirChat.Chat
  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat.{Channel, ChannelMembership, DirectConversation, Message, OutboxEvent}
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

  test "message creation is idempotent per user and client UUID", %{scope: scope} do
    channel = channel_fixture(%{name: "idempotency"})
    client_message_id = Ecto.UUID.generate()

    attrs = %{body: "  один раз  ", client_message_id: client_message_id}
    assert {:ok, first} = Chat.create_message(scope, channel, attrs)
    assert {:ok, repeated} = Chat.create_message(scope, channel, %{attrs | body: "один раз"})

    assert repeated.id == first.id
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(OutboxEvent, :count) == 1

    assert {:error, :idempotency_conflict} =
             Chat.create_message(scope, channel, %{
               body: "другое содержимое",
               client_message_id: client_message_id
             })

    assert {:ok, second} =
             Chat.create_message(scope, channel, %{
               body: "другое сообщение",
               client_message_id: Ecto.UUID.generate()
             })

    refute second.id == first.id
  end

  test "the same client UUID may be used by different users", %{scope: scope} do
    channel = channel_fixture(%{name: "per-user-idempotency"})
    other = user_fixture(%{login: "idempotency.other", display_name: "Другой"})
    client_message_id = Ecto.UUID.generate()

    assert {:ok, first} =
             Chat.create_message(scope, channel, %{
               body: "Первый",
               client_message_id: client_message_id
             })

    assert {:ok, second} =
             Chat.create_message(Scope.for_user(other), channel, %{
               body: "Второй",
               client_message_id: client_message_id
             })

    refute first.id == second.id
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

  test "direct conversation cursor pagination has stable page boundaries", %{
    scope: scope,
    user: user
  } do
    directs =
      for number <- 1..51 do
        other = user_fixture(%{login: "page.user.#{number}", display_name: "Page #{number}"})
        {first_id, second_id} = Enum.min_max([user.id, other.id])
        channel = channel_fixture(%{name: "direct-page-#{number}", kind: :private})

        Repo.insert!(
          DirectConversation.changeset(%DirectConversation{}, %{
            channel_id: channel.id,
            first_user_id: first_id,
            second_user_id: second_id,
            last_activity_at: DateTime.add(DateTime.utc_now(), number, :second)
          })
        )
      end

    {first_page, true} = Chat.list_direct_conversations(scope, nil)
    {second_page, false} = Chat.list_direct_conversations(scope, List.last(first_page))

    expected_ids = directs |> Enum.reverse() |> Enum.map(& &1.id)
    assert Enum.map(first_page ++ second_page, & &1.id) == expected_ids
    assert length(first_page) == 50
    assert length(second_page) == 1
  end

  test "message sending stays within the SQL telemetry budgets", %{scope: scope} do
    group = channel_fixture(%{name: "telemetry-group"})
    other = user_fixture(%{login: "telemetry.other", display_name: "Другой"})
    {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)

    group_events =
      count_repo_events(fn ->
        assert {:ok, _} = Chat.create_message(scope, group, %{body: "Два запроса"})
      end)

    assert length(group_events) <= 12, inspect(group_events)

    direct_events =
      count_repo_events(fn ->
        assert {:ok, _} = Chat.create_message(scope, direct.channel, %{body: "Пять событий"})
      end)

    assert length(direct_events) <= 13, inspect(direct_events)
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

    assert [%{id: invited_id, online?: false}] =
             Chat.search_invitable_users(member_scope, channel, "target")

    assert invited_id == invited.id
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

  test "own messages can be deleted within the delete window", %{scope: scope} do
    channel = channel_fixture(%{name: "delete-own"})
    message = message_fixture(scope, channel, %{body: "Уйдёт"})

    assert {:ok, deleted} = Chat.delete_message(scope, message.id)
    assert deleted.id == message.id
    refute Repo.get(Message, message.id)
  end

  test "own messages cannot be deleted after the delete window elapses", %{scope: scope} do
    channel = channel_fixture(%{name: "delete-expired"})
    message = message_fixture(scope, channel, %{body: "Просрочено"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second))
    |> Repo.update!()

    assert {:error, :forbidden} = Chat.delete_message(scope, message.id)
  end

  test "other members cannot delete someone else's message", %{scope: scope} do
    channel = channel_fixture(%{name: "delete-others"})
    other = user_fixture(%{login: "delete.other", display_name: "Другой"})
    message = message_fixture(Scope.for_user(other), channel, %{body: "Чужое"})

    assert {:error, :forbidden} = Chat.delete_message(scope, message.id)
  end

  test "channel owner may delete any message in their channel regardless of age", %{
    scope: owner_scope
  } do
    member = user_fixture(%{login: "delete.member", display_name: "Участник"})

    assert {:ok, channel} =
             Chat.create_channel(owner_scope, %{name: "owned-delete", kind: :public})

    assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)
    message = message_fixture(Scope.for_user(member), channel, %{body: "Старое"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second))
    |> Repo.update!()

    assert {:ok, _deleted} = Chat.delete_message(owner_scope, message.id)
    refute Repo.get(Message, message.id)
  end

  test "direct conversation participants cannot delete each other's messages", %{scope: scope} do
    other = user_fixture(%{login: "delete.direct.other", display_name: "Собеседник"})
    assert {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)
    assert {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "Привет"})

    assert {:error, :forbidden} = Chat.delete_message(Scope.for_user(other), message.id)
    assert {:ok, _deleted} = Chat.delete_message(scope, message.id)
    refute Repo.get(Message, message.id)
  end

  describe "can_delete_message?/3" do
    test "matches delete_message/2 for the same own-message-within-window rule", %{
      scope: scope,
      user: user
    } do
      channel = channel_fixture(%{name: "predicate-own"})
      message = message_fixture(scope, channel, %{body: "Сообщение"})

      assert Chat.can_delete_message?(user, message, channel)
    end

    test "matches delete_message/2 for the expired-window rule", %{scope: scope, user: user} do
      channel = channel_fixture(%{name: "predicate-expired"})
      message = message_fixture(scope, channel, %{body: "Просрочено"})

      message =
        message
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second)
        )
        |> Repo.update!()

      refute Chat.can_delete_message?(user, message, channel)
    end

    test "matches delete_message/2 for another member's message", %{user: user} do
      channel = channel_fixture(%{name: "predicate-others"})
      other = user_fixture(%{login: "predicate.other", display_name: "Другой"})
      message = message_fixture(Scope.for_user(other), channel, %{body: "Чужое"})

      refute Chat.can_delete_message?(user, message, channel)
    end

    test "matches delete_message/2 for the channel-owner override", %{scope: owner_scope} do
      owner = owner_scope.user
      member = user_fixture(%{login: "predicate.member", display_name: "Участник"})

      assert {:ok, channel} =
               Chat.create_channel(owner_scope, %{name: "predicate-owned", kind: :public})

      assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)
      message = message_fixture(Scope.for_user(member), channel, %{body: "Старое"})

      message =
        message
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second)
        )
        |> Repo.update!()

      assert Chat.can_delete_message?(owner, message, channel)
    end
  end

  test "own messages can be edited within the delete window", %{scope: scope} do
    channel = channel_fixture(%{name: "edit-own"})
    message = message_fixture(scope, channel, %{body: "Исходный текст"})

    message =
      message
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -2, :second))
      |> Repo.update!()

    assert {:ok, edited} = Chat.edit_message(scope, message.id, %{body: "Новый текст"})
    assert edited.id == message.id
    assert edited.body == "Новый текст"
    assert edited.updated_at != message.inserted_at
    assert Repo.get!(Message, message.id).body == "Новый текст"
  end

  test "own messages cannot be edited after the delete window elapses", %{scope: scope} do
    channel = channel_fixture(%{name: "edit-expired"})
    message = message_fixture(scope, channel, %{body: "Просрочено"})

    message
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second))
    |> Repo.update!()

    assert {:error, :forbidden} = Chat.edit_message(scope, message.id, %{body: "Поздно"})
  end

  test "other members cannot edit someone else's message", %{scope: scope} do
    channel = channel_fixture(%{name: "edit-others"})
    other = user_fixture(%{login: "edit.other", display_name: "Другой"})
    message = message_fixture(Scope.for_user(other), channel, %{body: "Чужое"})

    assert {:error, :forbidden} = Chat.edit_message(scope, message.id, %{body: "Подмена"})
  end

  test "channel owner cannot edit another member's message even within the window", %{
    scope: owner_scope
  } do
    member = user_fixture(%{login: "edit.member", display_name: "Участник"})

    assert {:ok, channel} =
             Chat.create_channel(owner_scope, %{name: "owned-edit", kind: :public})

    assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)
    message = message_fixture(Scope.for_user(member), channel, %{body: "Сообщение участника"})

    assert {:error, :forbidden} = Chat.edit_message(owner_scope, message.id, %{body: "Подмена"})
    assert Repo.get!(Message, message.id).body == "Сообщение участника"
  end

  test "direct conversation participants can edit their own message but not each other's", %{
    scope: scope
  } do
    other = user_fixture(%{login: "edit.direct.other", display_name: "Собеседник"})
    assert {:ok, direct} = Chat.get_or_create_direct_conversation(scope, other.id)
    assert {:ok, message} = Chat.create_message(scope, direct.channel, %{body: "Привет"})

    assert {:error, :forbidden} =
             Chat.edit_message(Scope.for_user(other), message.id, %{body: "Подмена"})

    assert {:ok, edited} = Chat.edit_message(scope, message.id, %{body: "Привет!"})
    assert edited.body == "Привет!"
  end

  test "editing a nonexistent message returns not_found", %{scope: scope} do
    assert {:error, :not_found} = Chat.edit_message(scope, "not-an-id", %{body: "Кто-то"})
  end

  test "editing a message with the same body is a no-op that does not touch updated_at", %{
    scope: scope
  } do
    channel = channel_fixture(%{name: "edit-noop"})
    message = message_fixture(scope, channel, %{body: "Без изменений"})

    assert {:ok, edited} = Chat.edit_message(scope, message.id, %{body: "Без изменений"})
    assert edited.updated_at == message.inserted_at
  end

  describe "can_edit_message?/2" do
    test "matches edit_message/3 for the same own-message-within-window rule", %{
      scope: scope,
      user: user
    } do
      channel = channel_fixture(%{name: "edit-predicate-own"})
      message = message_fixture(scope, channel, %{body: "Сообщение"})

      assert Chat.can_edit_message?(user, message)
    end

    test "matches edit_message/3 for the expired-window rule", %{scope: scope, user: user} do
      channel = channel_fixture(%{name: "edit-predicate-expired"})
      message = message_fixture(scope, channel, %{body: "Просрочено"})

      message =
        message
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(DateTime.utc_now(:second), -600, :second)
        )
        |> Repo.update!()

      refute Chat.can_edit_message?(user, message)
    end

    test "matches edit_message/3 for another member's message", %{user: user} do
      channel = channel_fixture(%{name: "edit-predicate-others"})
      other = user_fixture(%{login: "edit.predicate.other", display_name: "Другой"})
      message = message_fixture(Scope.for_user(other), channel, %{body: "Чужое"})

      refute Chat.can_edit_message?(user, message)
    end

    test "returns false for the channel owner on another member's message (no owner override)", %{
      scope: owner_scope
    } do
      owner = owner_scope.user
      member = user_fixture(%{login: "edit.predicate.member", display_name: "Участник"})

      assert {:ok, channel} =
               Chat.create_channel(owner_scope, %{name: "edit-predicate-owned", kind: :public})

      assert {:ok, _} = Chat.join_channel(Scope.for_user(member), channel.id)
      message = message_fixture(Scope.for_user(member), channel, %{body: "Сообщение"})

      refute Chat.can_edit_message?(owner, message)
    end
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

  defp count_repo_events(fun) do
    handler_id = "chat-query-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:elixir_chat, :repo, :query],
        fn _, _, metadata, _ ->
          send(test_pid, {:repo_query, metadata[:query]})
        end,
        nil
      )

    fun.()
    :telemetry.detach(handler_id)
    drain_repo_events([])
  end

  defp drain_repo_events(events) do
    receive do
      {:repo_query, query} -> drain_repo_events([query | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
