defmodule ElixirChat.Chat.Message do
  @moduledoc "A persisted chat message. Authentication will later supply the author."

  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :author_name, :string
    field :body, :string

    belongs_to :channel, ElixirChat.Chat.Channel

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:author_name, :body])
    |> update_change(:author_name, &String.trim/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:author_name, :body, :channel_id])
    |> validate_length(:author_name, min: 2, max: 40)
    |> validate_length(:body, min: 1, max: 4_000)
    |> foreign_key_constraint(:channel_id)
  end
end
