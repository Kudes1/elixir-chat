defmodule ElixirChat.AccountsTest do
  use ElixirChat.DataCase

  alias ElixirChat.Accounts
  alias ElixirChat.Accounts.{Scope, User, UserToken}
  alias ElixirChat.Chat.{Channel, ChannelMembership}
  alias ElixirChat.Repo

  test "registration invitations are one-time and keep the administrator-selected identity" do
    admin = user_fixture(%{login: "orbit.admin", role: :admin})
    scope = Scope.for_user(admin)

    assert {:ok, invitation, token} =
             Accounts.create_registration_invitation(scope, %{
               login: "New.User",
               display_name: "Новый пользователь"
             })

    refute invitation.token_hash == token
    assert {:ok, user} = Accounts.accept_invitation(token, "another-long-password")
    assert user.login == "new.user"
    assert user.display_name == "Новый пользователь"

    assert {:error, :invalid_invitation} =
             Accounts.accept_invitation(token, "another-long-password")
  end

  test "a newer invitation revokes the previous one" do
    admin = user_fixture(%{login: "orbit.admin", role: :admin})
    scope = Scope.for_user(admin)
    attrs = %{login: "invited.user", display_name: "Invited User"}

    assert {:ok, _, first} = Accounts.create_registration_invitation(scope, attrs)
    assert {:ok, _, second} = Accounts.create_registration_invitation(scope, attrs)

    assert {:error, :invalid_invitation} =
             Accounts.accept_invitation(first, "another-long-password")

    assert {:ok, _} = Accounts.accept_invitation(second, "another-long-password")
  end

  test "password reset revokes all server sessions" do
    admin = user_fixture(%{login: "orbit.admin", role: :admin})
    user = user_fixture(%{login: "regular.user"})
    token = Accounts.generate_session_token(user)

    assert {:ok, _, reset_token} = Accounts.create_password_reset(Scope.for_user(admin), user)
    assert {:ok, _} = Accounts.accept_invitation(reset_token, "replacement-password")
    assert Accounts.get_user_by_session_token(token) == nil
    refute Repo.exists?(from t in UserToken, where: t.user_id == ^user.id)
  end

  test "disabled users cannot authenticate" do
    user = user_fixture(%{disabled_at: DateTime.utc_now(:second)})
    assert Accounts.get_user_by_login_and_password(user.login, "long-test-password") == nil
  end

  test "messageable user search excludes self and disabled accounts" do
    current_user = user_fixture(%{login: "current.user", display_name: "Текущий"})
    match = user_fixture(%{login: "search.match", display_name: "Искомый пользователь"})

    _disabled =
      user_fixture(%{
        login: "disabled.match",
        display_name: "Искомый отключённый",
        disabled_at: DateTime.utc_now(:second)
      })

    scope = Scope.for_user(current_user)

    assert Accounts.search_messageable_users(scope, "ИСКОМЫЙ") == [match]
    assert current_user not in Accounts.search_messageable_users(scope, "")
  end

  test "invitation registration adds the new user to general" do
    admin = user_fixture(%{login: "general.admin", role: :admin})

    general =
      %Channel{owner_id: admin.id, is_general: true}
      |> Channel.changeset(%{name: "general", kind: :public, purpose: :group})
      |> Repo.insert!()

    assert {:ok, _, token} =
             Accounts.create_registration_invitation(Scope.for_user(admin), %{
               login: "general.member",
               display_name: "Новый участник"
             })

    assert {:ok, user} = Accounts.accept_invitation(token, "another-long-password")

    assert Repo.exists?(
             from membership in ChannelMembership,
               where: membership.channel_id == ^general.id and membership.user_id == ^user.id
           )
  end

  test "the first server admin claims unowned seed group channels" do
    channel =
      %Channel{}
      |> Channel.changeset(%{name: "product", kind: :public, purpose: :group})
      |> Repo.insert!()

    assert {:ok, {_invitation, token}} =
             Accounts.bootstrap_invitation("first.admin", "Первый администратор")

    assert {:ok, admin} = Accounts.accept_invitation(token, "another-long-password")
    assert Repo.get!(Channel, channel.id).owner_id == admin.id

    assert Repo.exists?(
             from membership in ChannelMembership,
               where: membership.channel_id == ^channel.id and membership.user_id == ^admin.id
           )
  end

  defp user_fixture(attrs) do
    role = Map.get(attrs, :role, :user)

    defaults = %{
      login: "user#{System.unique_integer([:positive])}",
      display_name: "Test User",
      password: "long-test-password"
    }

    user =
      %User{}
      |> User.registration_changeset(
        Map.merge(defaults, Map.drop(attrs, [:disabled_at, :role])),
        role
      )
      |> Repo.insert!()

    if attrs[:disabled_at],
      do: user |> Ecto.Changeset.change(disabled_at: attrs.disabled_at) |> Repo.update!(),
      else: user
  end
end
