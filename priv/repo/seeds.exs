alias ElixirChat.Accounts.User
alias ElixirChat.Chat.{Channel, ChannelMembership}
alias ElixirChat.Repo

import Ecto.Query

admin = Repo.one(from user in User, where: user.role == :admin, limit: 1)

channels = [
  %{
    name: "general",
    description: "Главное место для команды",
    kind: :public,
    purpose: :group,
    is_general: true
  },
  %{name: "product", description: "Идеи, планирование и релизы", kind: :public, purpose: :group},
  %{
    name: "random",
    description: "Всё, что не поместилось в другие каналы",
    kind: :public,
    purpose: :group
  }
]

Enum.each(channels, fn attrs ->
  channel =
    Repo.get_by(Channel, name: attrs.name) || Repo.insert!(Channel.changeset(%Channel{}, attrs))

  channel =
    if admin && is_nil(channel.owner_id) do
      Repo.update!(Ecto.Changeset.change(channel, owner_id: admin.id))
    else
      channel
    end

  if channel.is_general do
    Repo.all(from user in User, where: is_nil(user.disabled_at))
    |> Enum.each(fn user ->
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

  if admin do
    Repo.insert(
      ChannelMembership.changeset(%ChannelMembership{}, %{
        channel_id: channel.id,
        user_id: admin.id
      }),
      on_conflict: :nothing,
      conflict_target: [:channel_id, :user_id]
    )
  end

  if channel.name == "general" and
       not Repo.exists?(
         from message in ElixirChat.Chat.Message, where: message.channel_id == ^channel.id
       ) do
    Repo.insert!(
      ElixirChat.Chat.Message.historical_changeset(
        %ElixirChat.Chat.Message{channel_id: channel.id},
        %{
          author_name: "Ирина",
          body: "Добро пожаловать в Orbit! Это наш новый командный чат."
        }
      )
    )

    Repo.insert!(
      ElixirChat.Chat.Message.historical_changeset(
        %ElixirChat.Chat.Message{channel_id: channel.id},
        %{
          author_name: "Максим",
          body: "Отлично, я уже здесь. Давайте сделаем его удобным для всей команды."
        }
      )
    )
  end
end)
