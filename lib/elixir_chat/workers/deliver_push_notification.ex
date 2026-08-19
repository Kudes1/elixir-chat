defmodule ElixirChat.Workers.DeliverPushNotification do
  @moduledoc """
  Delivers one durable `ElixirChat.Notifications.PushDelivery` — replaces the
  old poll-based `ElixirChat.NotificationSender`, which used
  `Task.async_stream` for bounded concurrency.

  Unlike outbox publication, best-effort Web Push is allowed to give up: on
  the final attempt, a still-failing delivery is discarded outright (the row
  is deleted so it does not linger as forever-unrequestable) — matching the
  old "discard after 10 attempts" behavior. Concurrency is now the `:push`
  queue's job, replacing the old `Task.async_stream` bound.
  """

  use Oban.Worker, queue: :push, max_attempts: 10

  require Logger

  alias ElixirChat.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, attempt: attempt, max_attempts: max}) do
    case Notifications.deliver_delivery(id) do
      :retry when attempt >= max ->
        Notifications.discard_delivery(id, attempt)
        :ok

      :retry ->
        {:error, :delivery_failed}

      _terminal ->
        :ok
    end
  end
end
