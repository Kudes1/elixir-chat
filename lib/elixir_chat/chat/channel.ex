defmodule ElixirChat.Chat.Channel do
  @moduledoc "A public or private conversation space."

  use Ecto.Schema
  import Ecto.Changeset

  schema "channels" do
    field :name, :string
    field :description, :string
    field :kind, Ecto.Enum, values: [:public, :private]

    has_many :messages, ElixirChat.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :description, :kind])
    |> validate_required([:name, :kind])
    |> validate_format(:name, ~r/^[a-z0-9-]+$/)
    |> unique_constraint(:name)
  end
end
