defmodule ElixirChat.Chat.DirectConversation do
  @moduledoc "A private one-to-one conversation backed by a chat channel."

  use Ecto.Schema
  import Ecto.Changeset

  alias ElixirChat.Accounts.User
  alias ElixirChat.Chat.Channel

  schema "direct_conversations" do
    field :last_activity_at, :utc_datetime_usec

    belongs_to :channel, Channel
    belongs_to :first_user, User
    belongs_to :second_user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(direct_conversation, attrs) do
    direct_conversation
    |> cast(attrs, [:channel_id, :first_user_id, :second_user_id, :last_activity_at])
    |> validate_required([:channel_id, :first_user_id, :second_user_id, :last_activity_at])
    |> validate_ordered_users()
    |> foreign_key_constraint(:channel_id)
    |> foreign_key_constraint(:first_user_id)
    |> foreign_key_constraint(:second_user_id)
    |> unique_constraint(:channel_id)
    |> unique_constraint([:first_user_id, :second_user_id])
    |> check_constraint(:second_user_id,
      name: :direct_conversations_distinct_ordered_users,
      message: "must identify two distinct ordered users"
    )
  end

  def activity_changeset(direct_conversation, at) do
    direct_conversation
    |> change(last_activity_at: at)
    |> validate_required(:last_activity_at)
  end

  def other_user(%__MODULE__{first_user: %User{id: current_id}, second_user: other}, current_id),
    do: other

  def other_user(%__MODULE__{first_user: other, second_user: %User{id: current_id}}, current_id),
    do: other

  defp validate_ordered_users(changeset) do
    case {get_field(changeset, :first_user_id), get_field(changeset, :second_user_id)} do
      {first_user_id, second_user_id}
      when is_integer(first_user_id) and is_integer(second_user_id) and
             first_user_id < second_user_id ->
        changeset

      {first_user_id, second_user_id}
      when is_integer(first_user_id) and is_integer(second_user_id) ->
        add_error(changeset, :second_user_id, "must be greater than first_user_id")

      _other ->
        changeset
    end
  end
end
