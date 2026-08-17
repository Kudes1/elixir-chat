defmodule ElixirChat.Notifications.EndpointPolicy do
  @moduledoc false

  import Ecto.Changeset

  @default_host_suffixes [
    "fcm.googleapis.com",
    "updates.push.services.mozilla.com",
    "web.push.apple.com",
    "notify.windows.com"
  ]

  def validate(changeset, field) do
    validate_change(changeset, field, fn ^field, endpoint ->
      if valid?(endpoint), do: [], else: [{field, "is not an allowed Web Push endpoint"}]
    end)
  end

  def valid?(endpoint) when is_binary(endpoint) do
    with {:ok, %URI{} = uri} <- URI.new(endpoint),
         "https" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.fragment),
         true <- uri.port in [nil, 443] do
      allowed_host?(host)
    else
      _ -> false
    end
  end

  def valid?(_endpoint), do: false

  def allowed_host?(host) when is_binary(host) do
    host = String.downcase(host)

    Enum.any?(allowed_host_suffixes(), fn suffix ->
      host == suffix or String.ends_with?(host, "." <> suffix)
    end)
  end

  defp allowed_host_suffixes do
    Application.get_env(:elixir_chat, ElixirChat.Notifications, [])
    |> Keyword.get(:allowed_host_suffixes, @default_host_suffixes)
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(".") |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end
end
