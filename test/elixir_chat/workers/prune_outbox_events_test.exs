defmodule ElixirChat.Workers.PruneOutboxEventsTest do
  use ElixirChat.DataCase
  use Oban.Testing, repo: ElixirChat.Repo

  alias ElixirChat.Chat.OutboxEvent
  alias ElixirChat.Repo
  alias ElixirChat.Workers.PruneOutboxEvents

  @retention_days Application.compile_env!(:elixir_chat, ElixirChat.Retention)[
                    :outbox_events_days
                  ]

  test "deletes published events past the configured retention window, keeps recent ones" do
    now = DateTime.utc_now()

    old =
      event_fixture("channel:1")
      |> publish_at!(DateTime.add(now, -(@retention_days + 1) * 86_400))

    recent =
      event_fixture("channel:1")
      |> publish_at!(DateTime.add(now, -(@retention_days - 1) * 86_400))

    assert :ok = perform_job(PruneOutboxEvents, %{})

    refute Repo.get(OutboxEvent, old.id)
    assert Repo.get(OutboxEvent, recent.id)
  end

  test "never deletes unpublished events, no matter their age" do
    unpublished = event_fixture("channel:1")

    unpublished
    |> Ecto.Changeset.change(
      inserted_at: DateTime.add(DateTime.utc_now(), -(@retention_days + 30) * 86_400)
    )
    |> Repo.update!()

    assert :ok = perform_job(PruneOutboxEvents, %{})
    assert Repo.get(OutboxEvent, unpublished.id)
  end

  defp publish_at!(event, published_at) do
    event |> Ecto.Changeset.change(published_at: published_at) |> Repo.update!()
  end

  defp event_fixture(partition_key) do
    Repo.insert!(
      OutboxEvent.changeset(%OutboxEvent{}, %{
        event_id: Ecto.UUID.generate(),
        event_type: "message_created",
        partition_key: partition_key,
        payload: %{"version" => 1}
      })
    )
  end
end
