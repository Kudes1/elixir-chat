defmodule ElixirChat.Chat.OutboxEvent do
  @moduledoc "A durable message event awaiting realtime publication."

  use Ecto.Schema
  import Ecto.Changeset

  schema "outbox_events" do
    field :event_id, Ecto.UUID, autogenerate: true
    field :event_type, :string
    field :partition_key, :string
    field :payload, :map
    field :published_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_id, :event_type, :partition_key, :payload])
    |> validate_required([:event_id, :event_type, :partition_key, :payload])
    |> unique_constraint(:event_id)
  end
end
