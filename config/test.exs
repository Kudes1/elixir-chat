import Config

config :elixir_chat, :env, :test

# :inline runs a job's perform/1 synchronously, in the calling process, right
# where it's inserted (including inside an Ecto.Multi, after the wrapping
# transaction commits) — the same "no separate poller to race against"
# determinism the old `synchronous_wake_up: true`/`OutboxDispatcher.dispatch_now`
# test setup relied on, so existing tests that create a message and
# immediately assert on its broadcast/notify effects keep working unchanged.
config :elixir_chat, Oban, testing: :inline, plugins: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :elixir_chat, ElixirChat.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database:
    "#{System.get_env("POSTGRES_DB", "elixir_chat")}_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :elixir_chat, ElixirChatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ut98HLQ4Zn9j5/hvoeGHpgcU3/qQnMRr830oBJ62dmsvATKVl9ToUx776C6O+E0A",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
