defmodule ElixirChat.FakeWebPushAdapter do
  @moduledoc false

  @behaviour ElixirChat.Notifications.WebPushAdapter

  @impl true
  def send_notification(subscription_json, payload_json) do
    agent =
      Application.fetch_env!(:elixir_chat, ElixirChat.Notifications)
      |> Keyword.fetch!(:fake_adapter_agent)

    {test_pid, response} =
      Agent.get_and_update(agent, fn %{test_pid: test_pid, responses: responses} = state ->
        case responses do
          [response | rest] -> {{test_pid, response}, %{state | responses: rest}}
          [] -> {{test_pid, {:ok, :sent}}, state}
        end
      end)

    send(test_pid, {:web_push, subscription_json, payload_json})

    case response do
      {:raise, message} -> raise message
      {:throw, reason} -> throw(reason)
      response -> response
    end
  end
end
