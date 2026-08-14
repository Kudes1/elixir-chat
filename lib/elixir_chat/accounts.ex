defmodule ElixirChat.Accounts do
  import Ecto.Query
  alias Ecto.Multi
  alias ElixirChat.Repo
  alias ElixirChat.Accounts.{AuditEvent, Invitation, Scope, User, UserToken}
  alias ElixirChat.Chat.{Channel, ChannelMembership}

  @session_days 30
  @session_renewal_window_days 29
  @session_absolute_days 180

  def get_user_by_login_and_password(login, password)
      when is_binary(login) and is_binary(password) do
    user = Repo.get_by(User, login: String.downcase(String.trim(login)))
    if User.valid_password?(user || %User{}, password), do: user
  end

  def get_user_by_login_and_password(_, password) do
    if is_binary(password), do: Argon2.no_user_verify()
    nil
  end

  def generate_session_token(%User{disabled_at: nil} = user) do
    token = :crypto.strong_rand_bytes(32)
    now = DateTime.utc_now(:second)

    Repo.insert!(%UserToken{
      user_id: user.id,
      token: hash(token),
      context: "session",
      authenticated_at: now,
      expires_at: DateTime.add(now, @session_days, :day)
    })

    token
  end

  def get_user_by_session_token(token) when is_binary(token) do
    now = DateTime.utc_now(:second)
    absolute_cutoff = DateTime.add(now, -@session_absolute_days, :day)

    Repo.one(
      from t in UserToken,
        join: u in assoc(t, :user),
        where:
          t.context == "session" and
            t.token == ^hash(token) and t.expires_at > ^now and
            t.authenticated_at > ^absolute_cutoff and is_nil(u.disabled_at),
        select: u
    )
  end

  def get_user_by_session_token(_), do: nil

  def get_user_by_session_token_and_renew(token) when is_binary(token) do
    now = DateTime.utc_now(:second)
    absolute_cutoff = DateTime.add(now, -@session_absolute_days, :day)

    result =
      Repo.one(
        from t in UserToken,
          join: u in assoc(t, :user),
          where:
            t.context == "session" and
              t.token == ^hash(token) and t.expires_at > ^now and
              t.authenticated_at > ^absolute_cutoff and is_nil(u.disabled_at),
          select: {t, u}
      )

    case result do
      {%UserToken{} = session_token, %User{} = user} ->
        renewal_threshold = DateTime.add(now, @session_renewal_window_days, :day)

        absolute_expiry =
          DateTime.add(session_token.authenticated_at, @session_absolute_days, :day)

        requested_expiry = DateTime.add(now, @session_days, :day)
        renewed_expiry = Enum.min([requested_expiry, absolute_expiry], DateTime)

        renew? =
          DateTime.compare(session_token.expires_at, renewal_threshold) != :gt and
            DateTime.after?(renewed_expiry, session_token.expires_at)

        if renew? do
          Repo.update_all(
            from(t in UserToken,
              where: t.id == ^session_token.id and t.expires_at == ^session_token.expires_at
            ),
            set: [expires_at: renewed_expiry]
          )
        end

        {user, renew?}

      nil ->
        {nil, false}
    end
  end

  def get_user_by_session_token_and_renew(_), do: {nil, false}

  def delete_session_token(token) when is_binary(token),
    do:
      Repo.delete_all(
        from t in UserToken, where: t.context == "session" and t.token == ^hash(token)
      )

  def delete_session_token(_), do: :ok

  def change_password(%User{} = user, attrs), do: User.password_changeset(user, attrs)

  def update_password(%Scope{user: user}, current_password, attrs) do
    if User.valid_password?(user, current_password) do
      Multi.new()
      |> Multi.update(:user, User.password_changeset(user, attrs))
      |> Multi.delete_all(:tokens, from(t in UserToken, where: t.user_id == ^user.id))
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} ->
          disconnect_user(user)
          {:ok, user}

        {:error, :user, cs, _} ->
          {:error, cs}
      end
    else
      {:error, :invalid_password}
    end
  end

  def create_registration_invitation(%Scope{user: %{role: :admin} = actor}, attrs) do
    login = attrs |> value(:login) |> normalize_login()
    name = value(attrs, :display_name)

    with :ok <- validate_identity(login, name) do
      token = random_token()
      now = DateTime.utc_now(:second)

      Multi.new()
      |> Multi.update_all(
        :revoke,
        from(i in Invitation,
          where:
            i.kind == :user_registration and
              i.login == ^login and is_nil(i.used_at) and is_nil(i.revoked_at)
        ),
        set: [revoked_at: now]
      )
      |> Multi.insert(:invitation, %Invitation{
        kind: :user_registration,
        token_hash: hash(token),
        login: login,
        display_name: name,
        created_by_id: actor.id,
        expires_at: DateTime.add(now, 24, :hour)
      })
      |> Multi.insert(:audit, fn %{invitation: i} ->
        audit(actor, "invitation.created", "invitation", i.id, %{
          "kind" => "user_registration",
          "login" => login
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{invitation: invitation}} -> {:ok, invitation, encode(token)}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  def create_password_reset(%Scope{user: %{role: :admin} = actor}, %User{role: :user} = user),
    do: create_reset(user, actor)

  def create_password_reset(_, _), do: {:error, :unauthorized}

  def bootstrap_invitation(login, name) do
    Repo.transaction(fn ->
      Repo.query!("LOCK TABLE users IN EXCLUSIVE MODE")
      if Repo.exists?(from u in User, where: u.role == :admin), do: Repo.rollback(:admin_exists)
      token = random_token()
      now = DateTime.utc_now(:second)

      invitation =
        Repo.insert!(%Invitation{
          kind: :admin_bootstrap,
          token_hash: hash(token),
          login: normalize_login(login),
          display_name: name,
          expires_at: DateTime.add(now, 30, :minute)
        })

      Repo.insert!(audit(nil, "admin.bootstrap_created", "invitation", invitation.id, %{}))
      {invitation, encode(token)}
    end)
  end

  def admin_password_reset do
    case Repo.one(from u in User, where: u.role == :admin) do
      nil -> {:error, :admin_missing}
      user -> create_reset(user, nil)
    end
  end

  def get_invitation(token) do
    with {:ok, raw} <- decode(token),
         %Invitation{} = invitation <- Repo.get_by(Invitation, token_hash: hash(raw)) do
      {:ok, invitation}
    else
      _ -> {:error, :invalid}
    end
  end

  def accept_invitation(token, password) do
    with {:ok, raw} <- decode(token) do
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        invitation =
          Repo.one(from i in Invitation, where: i.token_hash == ^hash(raw), lock: "FOR UPDATE")

        unless invitation && is_nil(invitation.used_at) && is_nil(invitation.revoked_at) &&
                 DateTime.after?(invitation.expires_at, now),
               do: Repo.rollback(:invalid_invitation)

        case invitation.kind do
          kind when kind in [:user_registration, :admin_bootstrap] ->
            role = if kind == :admin_bootstrap, do: :admin, else: :user

            case Repo.insert(
                   User.registration_changeset(
                     %User{},
                     %{
                       login: invitation.login,
                       display_name: invitation.display_name,
                       password: password
                     },
                     role
                   )
                 ) do
              {:ok, user} ->
                add_to_general(user)
                if user.role == :admin, do: claim_unowned_group_channels(user)

                Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
                  set: [used_at: now]
                )

                Repo.insert!(
                  audit(invitation.created_by_id, "invitation.accepted", "user", user.id, %{
                    "kind" => to_string(kind)
                  })
                )

                user

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          :password_reset ->
            user = Repo.get!(User, invitation.user_id)

            case Repo.update(User.password_changeset(user, %{password: password})) do
              {:ok, user} ->
                Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id)

                Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
                  set: [used_at: now]
                )

                user

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
        end
      end)
      |> tap(fn
        {:ok, %User{} = user} ->
          if invitation_kind_for_token(raw) == :password_reset, do: disconnect_user(user)

        _ ->
          :ok
      end)
    end
  end

  def list_users(%Scope{user: %{role: :admin}}),
    do: Repo.all(from u in User, order_by: [asc: u.login])

  def list_users(_), do: []

  def search_messageable_users(scope, query, limit \\ 20)

  def search_messageable_users(%Scope{user: current_user}, query, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    pattern = "%#{String.trim(query)}%"

    User
    |> where([user], user.id != ^current_user.id and is_nil(user.disabled_at))
    |> where([user], ilike(user.display_name, ^pattern) or ilike(user.login, ^pattern))
    |> order_by([user], asc: user.display_name, asc: user.login)
    |> limit(^limit)
    |> Repo.all()
  end

  def search_messageable_users(_, _, _), do: []

  def update_user(%Scope{user: %{role: :admin} = actor}, %User{role: :user} = user, attrs) do
    Multi.new()
    |> Multi.update(:user, User.admin_changeset(user, attrs))
    |> Multi.delete_all(:tokens, fn %{user: updated} ->
      if updated.disabled_at,
        do: from(t in UserToken, where: t.user_id == ^updated.id),
        else: from(t in UserToken, where: false)
    end)
    |> Multi.insert(:audit, fn %{user: updated} ->
      audit(actor, "user.updated", "user", updated.id, %{
        "disabled" => not is_nil(updated.disabled_at)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        if user.disabled_at, do: disconnect_user(user)
        {:ok, user}

      {:error, _, reason, _} ->
        {:error, reason}
    end
  end

  def update_user(_, _, _), do: {:error, :forbidden}

  def transfer_admin(to_login) do
    Repo.transaction(fn ->
      users =
        Repo.all(
          from u in User,
            where: u.role == :admin or u.login == ^normalize_login(to_login),
            lock: "FOR UPDATE"
        )

      old = Enum.find(users, &(&1.role == :admin))
      new = Enum.find(users, &(&1.login == normalize_login(to_login)))

      unless old && new && is_nil(new.disabled_at) && old.id != new.id,
        do: Repo.rollback(:invalid_target)

      Repo.update_all(from(u in User, where: u.id == ^old.id), set: [role: :user])
      Repo.update_all(from(u in User, where: u.id == ^new.id), set: [role: :admin])
      Repo.insert!(audit(old, "admin.transferred", "user", new.id, %{"from_user_id" => old.id}))
      new
    end)
  end

  defp create_reset(user, actor) do
    token = random_token()
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.insert(:invitation, %Invitation{
      kind: :password_reset,
      token_hash: hash(token),
      user_id: user.id,
      created_by_id: actor && actor.id,
      expires_at: DateTime.add(now, 30, :minute)
    })
    |> Multi.insert(:audit, fn %{invitation: i} ->
      audit(actor, "password_reset.created", "user", user.id, %{"invitation_id" => i.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invitation: i}} -> {:ok, i, encode(token)}
      {:error, _, r, _} -> {:error, r}
    end
  end

  defp add_to_general(user) do
    case Repo.one(
           from channel in Channel,
             where:
               channel.purpose == :group and channel.is_general and
                 is_nil(channel.archived_at),
             lock: "FOR SHARE",
             limit: 1
         ) do
      nil ->
        :ok

      channel ->
        Repo.insert!(
          ChannelMembership.changeset(%ChannelMembership{}, %{
            channel_id: channel.id,
            user_id: user.id
          })
        )
    end
  end

  defp claim_unowned_group_channels(user) do
    channels =
      Repo.all(
        from channel in Channel,
          where: channel.purpose == :group and is_nil(channel.owner_id),
          lock: "FOR UPDATE"
      )

    Enum.each(channels, fn channel ->
      Repo.update!(Ecto.Changeset.change(channel, owner_id: user.id))

      Repo.insert(
        ChannelMembership.changeset(%ChannelMembership{}, %{
          channel_id: channel.id,
          user_id: user.id
        }),
        on_conflict: :nothing,
        conflict_target: [:channel_id, :user_id]
      )
    end)
  end

  defp audit(actor, action, type, id, metadata),
    do: %AuditEvent{
      actor_id: actor_id(actor),
      action: action,
      target_type: type,
      target_id: id,
      metadata: metadata
    }

  defp actor_id(%User{id: id}), do: id
  defp actor_id(id) when is_integer(id), do: id
  defp actor_id(_), do: nil
  defp value(attrs, key), do: attrs[key] || attrs[to_string(key)]

  defp validate_identity(login, name) when is_binary(login) and is_binary(name) do
    if Regex.match?(~r/^[a-z0-9._-]{3,32}$/, login) && String.length(String.trim(name)) in 2..80,
      do: :ok,
      else: {:error, :invalid_identity}
  end

  defp validate_identity(_, _), do: {:error, :invalid_identity}
  defp normalize_login(v) when is_binary(v), do: v |> String.trim() |> String.downcase()
  defp normalize_login(v), do: v
  defp random_token, do: :crypto.strong_rand_bytes(32)

  defp invitation_kind_for_token(raw) do
    case Repo.get_by(Invitation, token_hash: hash(raw)) do
      %Invitation{kind: kind} -> kind
      _ -> nil
    end
  end

  defp disconnect_user(user),
    do: ElixirChatWeb.Endpoint.broadcast("users_sessions:#{user.id}", "disconnect", %{})

  defp hash(token), do: :crypto.hash(:sha256, token)
  defp encode(token), do: Base.url_encode64(token, padding: false)

  defp decode(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> :error
    end
  end

  defp decode(_), do: :error
end
