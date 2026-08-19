# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Zoneinfo.TimeZoneDatabase

config :elixir_chat,
  ecto_repos: [ElixirChat.Repo],
  generators: [timestamp_type: :utc_datetime]

config :elixir_chat, ElixirChat.RepoDiagnostics,
  slow_query_ms: 500,
  queue_warn_ms: 100

config :elixir_chat, ElixirChat.Retention,
  outbox_events_days: 7,
  push_deliveries_days: 30,
  notifications_read_days: 90

config :elixir_chat, Oban,
  repo: ElixirChat.Repo,
  queues: [outbox: 10, push: 8, cleanup: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", ElixirChat.Workers.PruneOutboxEvents},
       {"0 3 * * *", ElixirChat.Workers.PrunePushDeliveries},
       {"0 3 * * *", ElixirChat.Workers.PruneNotifications}
     ]}
  ]

# Web Push endpoints are capability URLs. Never follow a provider response to
# another origin; this also closes a redirect-based SSRF path.
config :req, default_options: [redirect: false]

# Configure the endpoint
config :elixir_chat, ElixirChatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ElixirChatWeb.ErrorHTML, json: ElixirChatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirChat.PubSub,
  live_view: [signing_salt: "Z8BzujAh"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  elixir_chat: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  elixir_chat: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
