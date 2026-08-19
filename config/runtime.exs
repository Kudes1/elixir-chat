import Config

parse_positive_integer = fn name, default ->
  case Integer.parse(System.get_env(name, default)) do
    {value, ""} when value > 0 -> value
    _ -> raise "#{name} must be a positive integer"
  end
end

config :elixir_chat, ElixirChat.RepoDiagnostics,
  slow_query_ms: parse_positive_integer.("DB_SLOW_QUERY_MS", "500"),
  queue_warn_ms: parse_positive_integer.("DB_QUEUE_WARN_MS", "100")

config :elixir_chat, ElixirChat.Retention,
  outbox_events_days: parse_positive_integer.("RETENTION_OUTBOX_EVENTS_DAYS", "7"),
  push_deliveries_days: parse_positive_integer.("RETENTION_PUSH_DELIVERIES_DAYS", "30"),
  notifications_read_days: parse_positive_integer.("RETENTION_NOTIFICATIONS_READ_DAYS", "90")

config :elixir_chat, Oban,
  queues: [
    outbox: parse_positive_integer.("OBAN_OUTBOX_QUEUE_CONCURRENCY", "10"),
    push: parse_positive_integer.("OBAN_PUSH_QUEUE_CONCURRENCY", "8"),
    cleanup: parse_positive_integer.("OBAN_CLEANUP_QUEUE_CONCURRENCY", "1")
  ],
  plugins: [
    {Oban.Plugins.Pruner,
     max_age: parse_positive_integer.("OBAN_JOB_RETENTION_DAYS", "7") * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", ElixirChat.Workers.PruneOutboxEvents},
       {"0 3 * * *", ElixirChat.Workers.PrunePushDeliveries},
       {"0 3 * * *", ElixirChat.Workers.PruneNotifications}
     ]}
  ]

vapid_public_key = System.get_env("VAPID_PUBLIC_KEY", "")
vapid_private_key = System.get_env("VAPID_PRIVATE_KEY", "")
vapid_subject = System.get_env("VAPID_SUBJECT", "mailto:admin@example.com")

push_allowed_host_suffixes =
  System.get_env(
    "WEB_PUSH_ALLOWED_HOST_SUFFIXES",
    "fcm.googleapis.com,updates.push.services.mozilla.com,web.push.apple.com,notify.windows.com"
  )
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

push_enabled = vapid_public_key != "" and vapid_private_key != ""

if vapid_public_key == "" != (vapid_private_key == "") do
  raise "VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY must either both be set or both be empty"
end

if push_enabled do
  valid_key? = fn encoded, expected_size ->
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == expected_size
      :error -> false
    end
  end

  unless valid_key?.(vapid_public_key, 65) and valid_key?.(vapid_private_key, 32) do
    raise "VAPID_PUBLIC_KEY or VAPID_PRIVATE_KEY has an invalid base64url value or key size"
  end

  unless match?(
           {:ok, %URI{scheme: scheme}} when scheme in ["mailto", "https"],
           URI.new(vapid_subject)
         ) do
    raise "VAPID_SUBJECT must be a mailto: or https: URI"
  end
end

config :web_push_elixir,
  vapid_public_key: vapid_public_key,
  vapid_private_key: vapid_private_key,
  vapid_subject: vapid_subject

config :elixir_chat, ElixirChat.Notifications,
  enabled: push_enabled and config_env() != :test,
  allowed_host_suffixes: push_allowed_host_suffixes

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/elixir_chat start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :elixir_chat, ElixirChatWeb.Endpoint, server: true
end

config :elixir_chat, ElixirChatWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :elixir_chat, ElixirChatWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/elixir_chat_web/router\.ex$",
        ~r"lib/elixir_chat_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :elixir_chat, ElixirChat.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    pool_count: parse_positive_integer.("POOL_COUNT", "1"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  dns_cluster_query =
    case System.get_env("DNS_CLUSTER_QUERY") do
      nil -> :ignore
      "" -> :ignore
      query -> query
    end

  config :elixir_chat, :dns_cluster_query, dns_cluster_query

  config :elixir_chat, ElixirChatWeb.Endpoint,
    url: [host: "localhost", port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    check_origin: :conn,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :elixir_chat, ElixirChatWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :elixir_chat, ElixirChatWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
