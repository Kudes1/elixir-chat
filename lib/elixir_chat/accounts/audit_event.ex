defmodule ElixirChat.Accounts.AuditEvent do
  use Ecto.Schema

  schema "audit_events" do
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :metadata, :map, default: %{}
    belongs_to :actor, ElixirChat.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
