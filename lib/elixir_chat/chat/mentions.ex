defmodule ElixirChat.Chat.Mentions do
  @moduledoc """
  The single `@login` syntax used both when rendering a message body (to
  highlight mentions, see `ElixirChatWeb.ChatLive.Components.mention_fragments/1`)
  and when resolving a freshly created message to notification recipients
  (see `ElixirChat.Chat.persist_message_transaction/4`). Kept in one place so
  the two can never quietly drift apart.
  """

  @pattern ~r/(@[a-z0-9._-]+)/

  @doc "Splits `body` into `{:text, fragment}` / `{:mention, fragment}` pairs, in order, `fragment` including the leading `@`."
  def fragments(body) do
    @pattern
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.map(&classify/1)
  end

  defp classify(fragment) do
    if mention?(fragment), do: {:mention, fragment}, else: {:text, fragment}
  end

  defp mention?(fragment), do: Regex.match?(~r/^@[a-z0-9._-]+$/, fragment)

  @doc "Unique logins (lowercase, without the leading `@`) mentioned in `body`, in first-seen order."
  def logins(body) when is_binary(body) do
    body
    |> fragments()
    |> Enum.flat_map(fn
      {:mention, fragment} -> [String.trim_leading(fragment, "@")]
      {:text, _} -> []
    end)
    |> Enum.uniq()
  end
end
