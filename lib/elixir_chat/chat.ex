defmodule ElixirChat.Chat do
  @moduledoc "The chat domain: durable channels/messages and real-time broadcasts."

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias ElixirChat.Accounts
  alias ElixirChat.Accounts.{Scope, User}
  alias ElixirChat.Chat.{Channel, ChannelMembership, DirectConversation, Message}
  alias ElixirChat.Repo

  @pubsub ElixirChat.PubSub
  @message_page_size 50
  @direct_page_size 50
  @search_page_size 20

  def list_channels do
    Channel
    |> where([channel], channel.kind == :public and channel.purpose == :group)
    |> where([channel], is_nil(channel.archived_at))
    |> order_by([channel], asc: channel.name)
    |> Repo.all()
  end

  def list_channels(%Scope{user: user}) do
    Channel
    |> from(as: :channel)
    |> where([channel], channel.purpose == :group and is_nil(channel.archived_at))
    |> where(
      [channel],
      exists(
        from membership in ChannelMembership,
          where:
            membership.channel_id == parent_as(:channel).id and membership.user_id == ^user.id
      ) or
        (channel.kind == :public and
           not exists(
             from membership in ChannelMembership,
               where: membership.channel_id == parent_as(:channel).id
           ))
    )
    |> order_by([channel], asc: channel.name)
    |> Repo.all()
  end

  def list_available_public_channels(%Scope{user: user}) do
    Channel
    |> where(
      [channel],
      channel.purpose == :group and channel.kind == :public and is_nil(channel.archived_at)
    )
    |> where(
      [channel],
      not exists(
        from membership in ChannelMembership,
          where:
            membership.channel_id == parent_as(:channel).id and membership.user_id == ^user.id
      )
    )
    |> from(as: :channel)
    |> order_by([channel], asc: channel.name)
    |> select([channel], %{id: channel.id, name: channel.name, description: channel.description})
    |> Repo.all()
  end

  def list_channel_memberships(%Scope{} = scope, channel_or_id) do
    with {:ok, channel} <- resolve_group_channel(scope, channel_or_id) do
      memberships =
        ChannelMembership
        |> where([membership], membership.channel_id == ^channel.id)
        |> join(:inner, [membership], user in assoc(membership, :user))
        |> order_by([_membership, user], asc: user.display_name, asc: user.login)
        |> preload([_membership, user], user: user)
        |> Repo.all()

      {:ok, memberships}
    end
  end

  def list_memberships(scope, channel_or_id),
    do: list_channel_memberships(scope, channel_or_id)

  def change_channel(%Channel{} = channel, attrs \\ %{}),
    do: Channel.group_changeset(channel, attrs)

  def create_channel(%Scope{user: user}, attrs) do
    Multi.new()
    |> Multi.insert(
      :channel,
      %Channel{owner_id: user.id}
      |> Channel.group_changeset(attrs)
      |> Ecto.Changeset.put_change(:owner_id, user.id)
    )
    |> Multi.insert(:membership, fn %{channel: channel} ->
      ChannelMembership.changeset(%ChannelMembership{}, %{
        channel_id: channel.id,
        user_id: user.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{channel: channel}} ->
        broadcast_channel_change(channel, [user.id])
        {:ok, channel}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def update_channel(%Scope{user: user}, channel_or_id, attrs) do
    transact_locked_group(channel_or_id, fn channel ->
      with :ok <- require_owner(channel, user.id),
           :ok <- protect_general_update(channel, attrs) do
        case Repo.update(Channel.group_changeset(channel, attrs)) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> after_channel_result()
  end

  def archive_channel(%Scope{user: user}, channel_or_id) do
    transact_locked_group(channel_or_id, fn channel ->
      cond do
        channel.is_general ->
          Repo.rollback(:protected_channel)

        channel.owner_id != user.id ->
          Repo.rollback(:forbidden)

        true ->
          {:ok,
           Repo.update!(Ecto.Changeset.change(channel, archived_at: DateTime.utc_now(:second)))}
      end
    end)
    |> after_channel_result()
  end

  def join_channel(%Scope{user: user}, channel_or_id) do
    Repo.transaction(fn ->
      channel = lock_group_channel!(channel_or_id)

      unless channel.kind == :public and is_nil(channel.archived_at),
        do: Repo.rollback(:not_found)

      case Repo.insert(
             ChannelMembership.changeset(%ChannelMembership{}, %{
               channel_id: channel.id,
               user_id: user.id
             })
           ) do
        {:ok, _membership} ->
          channel

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :channel_id),
            do: Repo.rollback(:already_member),
            else: Repo.rollback(changeset)
      end
    end)
    |> normalize_transaction_result()
    |> after_membership_result(user.id)
  end

  def leave_channel(%Scope{user: user}, channel_or_id) do
    membership_change(channel_or_id, fn channel ->
      cond do
        channel.is_general ->
          Repo.rollback(:protected_channel)

        channel.owner_id == user.id ->
          Repo.rollback(:owner_must_transfer)

        true ->
          case Repo.get_by(ChannelMembership, channel_id: channel.id, user_id: user.id) do
            nil -> Repo.rollback(:not_member)
            membership -> Repo.delete!(membership) && channel
          end
      end
    end)
    |> after_membership_result(user.id)
  end

  def invite_member(%Scope{user: actor}, channel_or_id, user_or_id) do
    with {:ok, target_id} <- entity_id(user_or_id) do
      membership_change(channel_or_id, fn channel ->
        unless channel.kind == :private and member?(channel.id, actor.id),
          do: Repo.rollback(:forbidden)

        target = Repo.one(from user in User, where: user.id == ^target_id, lock: "FOR UPDATE")
        unless target && is_nil(target.disabled_at), do: Repo.rollback(:not_found)

        case Repo.insert(
               ChannelMembership.changeset(%ChannelMembership{}, %{
                 channel_id: channel.id,
                 user_id: target.id
               })
             ) do
          {:ok, _} -> channel
          {:error, _} -> Repo.rollback(:already_member)
        end
      end)
      |> after_membership_result(target_id)
    end
  end

  def remove_member(%Scope{user: actor}, channel_or_id, user_or_id) do
    with {:ok, target_id} <- entity_id(user_or_id) do
      membership_change(channel_or_id, fn channel ->
        cond do
          channel.kind != :private ->
            Repo.rollback(:forbidden)

          channel.owner_id != actor.id ->
            Repo.rollback(:forbidden)

          target_id == actor.id ->
            Repo.rollback(:owner_must_transfer)

          true ->
            case Repo.get_by(ChannelMembership, channel_id: channel.id, user_id: target_id) do
              nil -> Repo.rollback(:not_member)
              membership -> Repo.delete!(membership) && channel
            end
        end
      end)
      |> after_membership_result(target_id)
    end
  end

  def transfer_ownership(%Scope{user: actor}, channel_or_id, user_or_id) do
    with {:ok, target_id} <- entity_id(user_or_id) do
      transact_locked_group(channel_or_id, fn channel ->
        target = Repo.one(from user in User, where: user.id == ^target_id, lock: "FOR UPDATE")

        cond do
          channel.owner_id != actor.id -> Repo.rollback(:forbidden)
          target_id == actor.id -> Repo.rollback(:invalid_target)
          is_nil(target) or not is_nil(target.disabled_at) -> Repo.rollback(:invalid_target)
          not member?(channel.id, target_id) -> Repo.rollback(:not_member)
          true -> {:ok, Repo.update!(Ecto.Changeset.change(channel, owner_id: target_id))}
        end
      end)
      |> after_channel_result()
    end
  end

  def search_invitable_users(%Scope{user: actor}, channel_or_id, query, limit \\ 20)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    with {:ok, channel} <- resolve_group_channel(%Scope{user: actor}, channel_or_id),
         true <- channel.kind == :private do
      member_ids =
        Repo.all(
          from membership in ChannelMembership,
            where: membership.channel_id == ^channel.id,
            select: membership.user_id
        )

      excluded_ids = Enum.uniq([actor.id | member_ids])
      online = ElixirChat.OnlineUsers.search(query, excluded_ids, limit)
      remaining = limit - length(online)

      if remaining > 0 and String.length(String.trim(query)) >= 3 do
        online ++
          Accounts.search_active_users(
            query,
            excluded_ids ++ Enum.map(online, & &1.id),
            remaining
          )
      else
        online
      end
    else
      _ -> []
    end
  end

  def list_direct_conversations(%Scope{user: user}) do
    {directs, _has_more?} = list_direct_conversations(%Scope{user: user}, nil)
    directs
  end

  def list_direct_conversations(%Scope{user: user}, cursor) do
    {cursor_at, cursor_id} = direct_cursor_params(cursor)
    limit = @direct_page_size + 1

    sql = """
    SELECT id FROM (
      (SELECT id, last_activity_at FROM direct_conversations
       WHERE first_user_id = $1
         AND ($2::timestamptz IS NULL OR (last_activity_at, id) < ($2, $3))
       ORDER BY last_activity_at DESC, id DESC LIMIT $4)
      UNION ALL
      (SELECT id, last_activity_at FROM direct_conversations
       WHERE second_user_id = $1
         AND ($2::timestamptz IS NULL OR (last_activity_at, id) < ($2, $3))
       ORDER BY last_activity_at DESC, id DESC LIMIT $4)
    ) AS conversations
    ORDER BY last_activity_at DESC, id DESC
    LIMIT $4
    """

    ids =
      Repo.query!(sql, [user.id, cursor_at, cursor_id, limit]).rows
      |> List.flatten()

    directs = load_directs(ids)
    {Enum.take(directs, @direct_page_size), length(ids) > @direct_page_size}
  end

  def get_channel(id) do
    case parse_id(id) do
      {:ok, channel_id} -> get_public_channel_by_id(channel_id)
      :error -> {:error, :not_found}
    end
  end

  def get_channel(%Scope{} = scope, id) do
    with {:ok, channel_id} <- parse_id(id),
         %Channel{} = channel <- authorized_group_channel(scope, channel_id) do
      {:ok, channel}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_channel_by_public_id(%Scope{} = scope, public_id) do
    with {:ok, public_id} <- parse_public_id(public_id),
         %Channel{} = channel <- authorized_group_channel_by_public_id(scope, public_id) do
      {:ok, channel}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_direct_conversation(%Scope{user: user}, id) do
    with {:ok, direct_id} <- parse_id(id),
         %DirectConversation{} = direct <-
           Repo.one(
             from direct in DirectConversation,
               where:
                 direct.id == ^direct_id and
                   (direct.first_user_id == ^user.id or direct.second_user_id == ^user.id),
               preload: [:channel, :first_user, :second_user]
           ) do
      {:ok, direct}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_direct_conversation_by_public_id(%Scope{user: user}, public_id) do
    with {:ok, public_id} <- parse_public_id(public_id),
         %DirectConversation{} = direct <-
           Repo.one(
             from direct in DirectConversation,
               join: channel in assoc(direct, :channel),
               where:
                 channel.public_id == ^public_id and channel.purpose == :direct and
                   (direct.first_user_id == ^user.id or direct.second_user_id == ^user.id),
               preload: [:channel, :first_user, :second_user]
           ) do
      {:ok, direct}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_or_create_direct_conversation(%Scope{user: current_user}, other_user_id) do
    with {:ok, other_user_id} <- parse_id(other_user_id),
         true <- other_user_id != current_user.id,
         %User{disabled_at: nil} <- Repo.get(User, other_user_id) do
      {first_user_id, second_user_id} = ordered_user_ids(current_user.id, other_user_id)

      case get_direct_by_users(first_user_id, second_user_id) do
        %DirectConversation{} = direct -> {:ok, direct}
        nil -> create_direct_conversation(first_user_id, second_user_id)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def get_default_channel do
    query =
      from channel in Channel,
        where:
          channel.kind == :public and channel.purpose == :group and is_nil(channel.archived_at)

    channel =
      Repo.one(from channel in query, where: channel.name == "general", limit: 1) ||
        Repo.one(from channel in query, order_by: [asc: channel.name], limit: 1)

    if channel, do: {:ok, channel}, else: {:error, :not_found}
  end

  def get_default_channel(%Scope{} = scope) do
    channels = list_channels(scope)
    channel = Enum.find(channels, & &1.is_general) || List.first(channels)
    if channel, do: {:ok, channel}, else: {:error, :not_found}
  end

  def list_recent_messages(channel_id), do: list_recent_messages(channel_id, @message_page_size)

  def list_recent_messages(%Scope{} = scope, channel_id),
    do: list_recent_messages(scope, channel_id, @message_page_size)

  def list_recent_messages(channel_id, page_size) do
    channel_id
    |> messages_query()
    |> message_page(page_size)
  end

  def list_recent_messages(%Scope{} = scope, channel_id, page_size) do
    with {:ok, channel} <- readable_channel(scope, channel_id) do
      {:ok, list_recent_messages(channel.id, page_size)}
    end
  end

  def list_messages(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> preload([:channel, :user])
    |> Repo.all()
  end

  def list_messages(%Scope{} = scope, channel_id) do
    with {:ok, channel} <- readable_channel(scope, channel_id) do
      {:ok, list_messages(channel.id)}
    end
  end

  def list_messages_before(channel_id, %Message{} = cursor),
    do: list_messages_before(channel_id, cursor, @message_page_size)

  def list_messages_before(%Scope{} = scope, channel_id, cursor),
    do: list_messages_before(scope, channel_id, cursor, @message_page_size)

  def list_messages_before(channel_id, %Message{} = cursor, page_size) do
    channel_id
    |> messages_query()
    |> where(
      [message],
      fragment(
        "(?, ?) < (?, ?)",
        message.inserted_at,
        message.id,
        ^cursor.inserted_at,
        ^cursor.id
      )
    )
    |> message_page(page_size)
  end

  def list_messages_before(%Scope{} = scope, channel_id, cursor, page_size) do
    with {:ok, channel} <- readable_channel(scope, channel_id) do
      {:ok, list_messages_before(channel.id, cursor, page_size)}
    end
  end

  def list_messages_after(channel_id, %Message{} = cursor),
    do: list_messages_after(channel_id, cursor, @message_page_size)

  def list_messages_after(%Scope{} = scope, channel_id, cursor),
    do: list_messages_after(scope, channel_id, cursor, @message_page_size)

  def list_messages_after(channel_id, %Message{} = cursor, page_size) do
    messages =
      Message
      |> where([message], message.channel_id == ^channel_id)
      |> where(
        [message],
        fragment(
          "(?, ?) > (?, ?)",
          message.inserted_at,
          message.id,
          ^cursor.inserted_at,
          ^cursor.id
        )
      )
      |> order_by([message], asc: message.inserted_at, asc: message.id)
      |> preload([:channel, :user])
      |> limit(^(page_size + 1))
      |> Repo.all()

    {Enum.take(messages, page_size), length(messages) > page_size}
  end

  def list_messages_after(%Scope{} = scope, channel_id, cursor, page_size) do
    with {:ok, channel} <- readable_channel(scope, channel_id) do
      {:ok, list_messages_after(channel.id, cursor, page_size)}
    end
  end

  def search_messages(%Scope{} = scope, channel_id, query, cursor \\ nil)
      when is_binary(query) do
    query = String.trim(query)

    with true <- query != "",
         {:ok, channel} <- readable_channel(scope, channel_id) do
      messages =
        channel.id
        |> message_search_query(query, cursor)
        |> limit(^(@search_page_size + 1))
        |> Repo.all()

      {:ok, {Enum.take(messages, @search_page_size), length(messages) > @search_page_size}}
    else
      false -> {:ok, {[], false}}
      {:error, _} = error -> error
    end
  end

  def message_window(%Scope{} = scope, channel_id, message_id, size \\ 150)
      when is_integer(size) and size > 0 and size <= 150 do
    with {:ok, channel} <- readable_channel(scope, channel_id),
         {:ok, message_id} <- parse_id(message_id),
         %Message{} = target <-
           Repo.one(
             Message
             |> where([message], message.channel_id == ^channel.id and message.id == ^message_id)
             |> preload([:channel, :user])
           ) do
      before_size = div(size - 1, 2)
      after_size = size - before_size - 1
      {before, has_older?} = list_messages_before(channel.id, target, before_size)
      {after_messages, has_newer?} = list_messages_after(channel.id, target, after_size)
      {:ok, {before ++ [target] ++ after_messages, has_older?, has_newer?}}
    else
      _ -> {:error, :not_found}
    end
  end

  def subscribe(channel_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(channel_id))
  def subscribe_user(user_id), do: Phoenix.PubSub.subscribe(@pubsub, user_topic(user_id))
  def subscribe_catalog, do: Phoenix.PubSub.subscribe(@pubsub, "chat:catalog")

  def create_message(%Scope{} = scope, %Channel{} = channel, attrs) do
    with {:ok, conversation} <- authorize_conversation(scope, channel) do
      persist_message(scope, conversation, attrs)
    end
  end

  def topic(channel_id), do: "chat:#{channel_id}"
  def user_topic(user_id), do: "chat:user:#{user_id}"

  defp create_direct_conversation(first_user_id, second_user_id) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.insert(
      :channel,
      Channel.changeset(%Channel{}, %{
        name: "direct-#{first_user_id}-#{second_user_id}",
        kind: :private,
        purpose: :direct
      })
    )
    |> Multi.insert(:direct, fn %{channel: channel} ->
      DirectConversation.changeset(%DirectConversation{}, %{
        channel_id: channel.id,
        first_user_id: first_user_id,
        second_user_id: second_user_id,
        last_activity_at: now
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{direct: direct}} ->
        direct = preload_direct(direct)
        broadcast_direct(direct, {:direct_conversation_updated, direct})
        {:ok, direct}

      {:error, _operation, %Ecto.Changeset{}, _changes} ->
        case get_direct_by_users(first_user_id, second_user_id) do
          %DirectConversation{} = direct -> {:ok, direct}
          nil -> {:error, :conflict}
        end
    end
  end

  defp authorize_conversation(%Scope{} = scope, %Channel{purpose: :group, id: channel_id}) do
    case authorized_group_channel(scope, channel_id) do
      %Channel{} = channel -> {:ok, {:public, channel}}
      nil -> {:error, :forbidden}
    end
  end

  defp authorize_conversation(%Scope{user: user}, %Channel{purpose: :direct, id: channel_id}) do
    query =
      from direct in DirectConversation,
        join: channel in assoc(direct, :channel),
        join: first_user in assoc(direct, :first_user),
        join: second_user in assoc(direct, :second_user),
        where:
          direct.channel_id == ^channel_id and
            (direct.first_user_id == ^user.id or direct.second_user_id == ^user.id),
        preload: [channel: channel, first_user: first_user, second_user: second_user]

    case Repo.one(query) do
      %DirectConversation{} = direct ->
        if is_nil(DirectConversation.other_user(direct, user.id).disabled_at),
          do: {:ok, {:direct, direct}},
          else: {:error, :recipient_disabled}

      nil ->
        {:error, :forbidden}
    end
  end

  defp authorize_conversation(_scope, _channel), do: {:error, :forbidden}

  defp persist_message(%Scope{user: user}, {:public, channel}, attrs) do
    case insert_message(user, channel, attrs) do
      {:ok, message} ->
        Phoenix.PubSub.broadcast(@pubsub, topic(channel.id), {:message_created, message})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp persist_message(%Scope{user: user}, {:direct, direct}, attrs) do
    now = DateTime.utc_now()
    changeset = message_changeset(user, direct.channel, attrs)

    Multi.new()
    |> Multi.insert(:message, changeset)
    |> Multi.update(:direct, DirectConversation.activity_changeset(direct, now))
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message, direct: direct}} ->
        message = with_message_associations(message, user, direct.channel)
        broadcast_direct(direct, {:direct_message_created, direct, message})
        {:ok, message}

      {:error, :message, changeset, _changes} ->
        {:error, changeset}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp insert_message(user, channel, attrs) do
    user
    |> message_changeset(channel, attrs)
    |> Repo.insert()
    |> case do
      {:ok, message} -> {:ok, with_message_associations(message, user, channel)}
      error -> error
    end
  end

  defp message_changeset(user, channel, attrs) do
    %Message{channel_id: channel.id, user_id: user.id, author_name: user.display_name}
    |> Message.changeset(attrs)
  end

  defp with_message_associations(message, user, channel),
    do: %{message | user: user, channel: channel}

  defp get_public_channel_by_id(id) do
    case Repo.one(
           from channel in Channel,
             where:
               channel.id == ^id and channel.kind == :public and channel.purpose == :group and
                 is_nil(channel.archived_at)
         ) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  defp get_direct_by_users(first_user_id, second_user_id) do
    DirectConversation
    |> where(
      [direct],
      direct.first_user_id == ^first_user_id and direct.second_user_id == ^second_user_id
    )
    |> preload([:channel, :first_user, :second_user])
    |> Repo.one()
  end

  defp preload_direct(direct),
    do: Repo.preload(direct, [:channel, :first_user, :second_user], force: true)

  defp broadcast_direct(direct, event) do
    Phoenix.PubSub.broadcast(@pubsub, user_topic(direct.first_user_id), event)
    Phoenix.PubSub.broadcast(@pubsub, user_topic(direct.second_user_id), event)
  end

  defp ordered_user_ids(first_id, second_id) when first_id < second_id,
    do: {first_id, second_id}

  defp ordered_user_ids(first_id, second_id), do: {second_id, first_id}

  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_id(_id), do: :error

  defp parse_public_id(public_id) when is_binary(public_id), do: Ecto.UUID.cast(public_id)
  defp parse_public_id(_public_id), do: :error

  defp authorized_group_channel(%Scope{user: user}, channel_id) do
    Repo.one(
      from channel in Channel,
        as: :channel,
        where:
          channel.id == ^channel_id and channel.purpose == :group and
            is_nil(channel.archived_at),
        where:
          exists(
            from membership in ChannelMembership,
              where:
                membership.channel_id == parent_as(:channel).id and
                  membership.user_id == ^user.id
          ) or
            (channel.kind == :public and
               not exists(
                 from membership in ChannelMembership,
                   where: membership.channel_id == parent_as(:channel).id
               ))
    )
  end

  defp authorized_group_channel_by_public_id(%Scope{user: user}, public_id) do
    Repo.one(
      from channel in Channel,
        as: :channel,
        where:
          channel.public_id == ^public_id and channel.purpose == :group and
            is_nil(channel.archived_at),
        where:
          exists(
            from membership in ChannelMembership,
              where:
                membership.channel_id == parent_as(:channel).id and
                  membership.user_id == ^user.id
          ) or
            (channel.kind == :public and
               not exists(
                 from membership in ChannelMembership,
                   where: membership.channel_id == parent_as(:channel).id
               ))
    )
  end

  defp resolve_group_channel(%Scope{} = scope, %Channel{id: id}), do: get_channel(scope, id)
  defp resolve_group_channel(%Scope{} = scope, id), do: get_channel(scope, id)

  defp readable_channel(%Scope{user: user} = scope, channel_id) do
    case get_channel(scope, channel_id) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, :not_found} ->
        with {:ok, id} <- parse_id(channel_id),
             %Channel{} = channel <-
               Repo.one(
                 from channel in Channel,
                   join: direct in DirectConversation,
                   on: direct.channel_id == channel.id,
                   where:
                     channel.id == ^id and channel.purpose == :direct and
                       (direct.first_user_id == ^user.id or direct.second_user_id == ^user.id)
               ) do
          {:ok, channel}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp entity_id(%{id: id}), do: parse_id(id)
  defp entity_id(id), do: parse_id(id)

  defp transact_locked_group(channel_or_id, fun) do
    Repo.transaction(fn ->
      channel = lock_group_channel!(channel_or_id)
      fun.(channel)
    end)
    |> normalize_transaction_result()
  end

  defp membership_change(channel_or_id, fun), do: transact_locked_group(channel_or_id, fun)

  defp lock_group_channel!(channel_or_id) do
    with {:ok, id} <- entity_id(channel_or_id),
         %Channel{} = channel <-
           Repo.one(
             from channel in Channel,
               where: channel.id == ^id and channel.purpose == :group,
               lock: "FOR UPDATE"
           ) do
      channel
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp member?(channel_id, user_id),
    do:
      Repo.exists?(
        from m in ChannelMembership, where: m.channel_id == ^channel_id and m.user_id == ^user_id
      )

  defp require_owner(%Channel{owner_id: user_id}, user_id), do: :ok
  defp require_owner(_channel, _user_id), do: {:error, :forbidden}

  defp protect_general_update(%Channel{is_general: false}, _attrs), do: :ok

  defp protect_general_update(%Channel{} = channel, attrs) do
    name = attrs[:name] || attrs["name"] || channel.name
    kind = attrs[:kind] || attrs["kind"] || channel.kind

    if name == channel.name and kind in [:public, "public"],
      do: :ok,
      else: {:error, :protected_channel}
  end

  defp normalize_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp after_channel_result({:ok, %Channel{} = channel} = result) do
    ids = membership_user_ids(channel.id)
    broadcast_channel_change(channel, ids)
    result
  end

  defp after_channel_result(result), do: result

  defp after_membership_result({:ok, %Channel{} = channel} = result, user_id) do
    broadcast_channel_change(channel, Enum.uniq([user_id | membership_user_ids(channel.id)]))
    result
  end

  defp after_membership_result(result, _user_id), do: result

  defp membership_user_ids(channel_id) do
    Repo.all(
      from membership in ChannelMembership,
        where: membership.channel_id == ^channel_id,
        select: membership.user_id
    )
  end

  defp broadcast_channel_change(channel, user_ids) do
    Enum.each(user_ids, fn user_id ->
      Phoenix.PubSub.broadcast(@pubsub, user_topic(user_id), {:channels_changed, channel.id})
    end)

    Phoenix.PubSub.broadcast(@pubsub, "chat:catalog", {:catalog_changed, channel.id})
  end

  defp messages_query(channel_id) do
    Message
    |> where([message], message.channel_id == ^channel_id)
    |> order_by([message], desc: message.inserted_at, desc: message.id)
    |> preload([:channel, :user])
  end

  defp message_search_query(channel_id, query, cursor) do
    base =
      from message in Message,
        join: channel in assoc(message, :channel),
        left_join: user in assoc(message, :user),
        where:
          message.channel_id == ^channel_id and
            fragment(
              "to_tsvector('simple', ?) @@ websearch_to_tsquery('simple', ?)",
              message.body,
              ^query
            ),
        order_by: [desc: message.inserted_at, desc: message.id],
        preload: [channel: channel, user: user]

    case cursor do
      %Message{} = message ->
        where(
          base,
          [message],
          fragment(
            "(?, ?) < (?, ?)",
            message.inserted_at,
            message.id,
            ^message.inserted_at,
            ^message.id
          )
        )

      _ ->
        base
    end
  end

  defp direct_cursor_params(nil), do: {nil, nil}
  defp direct_cursor_params(%{last_activity_at: at, id: id}), do: {at, id}

  defp load_directs([]), do: []

  defp load_directs(ids) do
    directs =
      Repo.all(
        from direct in DirectConversation,
          join: channel in assoc(direct, :channel),
          join: first_user in assoc(direct, :first_user),
          join: second_user in assoc(direct, :second_user),
          where: direct.id in ^ids,
          preload: [channel: channel, first_user: first_user, second_user: second_user]
      )

    by_id = Map.new(directs, &{&1.id, &1})
    Enum.flat_map(ids, fn id -> if direct = by_id[id], do: [direct], else: [] end)
  end

  defp message_page(query, page_size) do
    messages =
      query
      |> limit(^(page_size + 1))
      |> Repo.all()

    {messages |> Enum.take(page_size) |> Enum.reverse(), length(messages) > page_size}
  end
end
