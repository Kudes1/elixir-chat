alias ElixirChat.Accounts.User
alias ElixirChat.Chat.{Channel, ChannelMembership, DirectConversation, Message}
alias ElixirChat.Repo

import Ecto.Query

password = "orbit-password-123"

upsert_user = fn login, name, role ->
  Repo.get_by(User, login: login) ||
    Repo.insert!(User.registration_changeset(%User{}, %{login: login, display_name: name, password: password}, role))
end

admin = upsert_user.("admin", "Администратор Orbit", :admin)
user = upsert_user.("orbit-user", "Пользователь Orbit", :user)
peer = upsert_user.("orbit-peer", "Собеседник Orbit", :user)

for number <- 1..32 do
  upsert_user.("member-#{number}", "Участник с длинным именем #{number}", :user)
end

general =
  Repo.get_by(Channel, name: "general") ||
    Repo.insert!(Channel.changeset(%Channel{}, %{name: "general", description: "Основной канал E2E", kind: :public, purpose: :group, is_general: true, owner_id: user.id}))

for attrs <- [
      %{name: "product", description: "Продуктовые новости", kind: :public, purpose: :group, owner_id: user.id},
      %{name: "private-team", description: "Приватная команда", kind: :private, purpose: :group, owner_id: user.id}
    ] do
  Repo.get_by(Channel, name: attrs.name) || Repo.insert!(Channel.changeset(%Channel{}, attrs))
end

for member <- [admin, user, peer] do
  Repo.insert(ChannelMembership.changeset(%ChannelMembership{}, %{channel_id: general.id, user_id: member.id}), on_conflict: :nothing, conflict_target: [:channel_id, :user_id])
end

unless Repo.exists?(from message in Message, where: message.channel_id == ^general.id) do
  for {author, body} <- [{user, "Сообщение пользователя для проверки touch-меню"}, {peer, "Ответ собеседника"}, {user, "Продолжение сообщения"}] do
    %Message{channel_id: general.id, user_id: author.id, author_name: author.display_name}
    |> Message.changeset(%{body: body, client_message_id: Ecto.UUID.generate()})
    |> Repo.insert!()
  end
end

{first, second} = if user.id < peer.id, do: {user, peer}, else: {peer, user}

unless Repo.exists?(from direct in DirectConversation, where: direct.first_user_id == ^first.id and direct.second_user_id == ^second.id) do
  channel = Repo.insert!(Channel.changeset(%Channel{}, %{name: "direct-#{first.id}-#{second.id}", kind: :private, purpose: :direct}))
  Repo.insert!(DirectConversation.changeset(%DirectConversation{}, %{channel_id: channel.id, first_user_id: first.id, second_user_id: second.id, last_activity_at: DateTime.utc_now()}))
end
