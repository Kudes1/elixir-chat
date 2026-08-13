alias ElixirChat.Chat.Channel
alias ElixirChat.Repo

import Ecto.Query

channels = [
  %{name: "general", description: "Главное место для команды", kind: :public},
  %{name: "product", description: "Идеи, планирование и релизы", kind: :public},
  %{name: "random", description: "Всё, что не поместилось в другие каналы", kind: :public}
]

Enum.each(channels, fn attrs ->
  channel =
    Repo.get_by(Channel, name: attrs.name) || Repo.insert!(Channel.changeset(%Channel{}, attrs))

  if channel.name == "general" and
       not Repo.exists?(
         from message in ElixirChat.Chat.Message, where: message.channel_id == ^channel.id
       ) do
    Repo.insert!(
      ElixirChat.Chat.Message.changeset(%ElixirChat.Chat.Message{channel_id: channel.id}, %{
        author_name: "Ирина",
        body: "Добро пожаловать в Orbit! Это наш новый командный чат."
      })
    )

    Repo.insert!(
      ElixirChat.Chat.Message.changeset(%ElixirChat.Chat.Message{channel_id: channel.id}, %{
        author_name: "Максим",
        body: "Отлично, я уже здесь. Давайте сделаем его удобным для всей команды."
      })
    )
  end
end)
