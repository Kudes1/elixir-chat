# Technology stack

- Application: Elixir OTP app `:elixir_chat`, product name Orbit. `mix.exs` accepts Elixir `~> 1.17`; Docker pins Elixir 1.19.1 and Erlang/OTP 27.3.4.3 on Debian bookworm.
- Web: Phoenix 1.8.9, Phoenix LiveView 1.2.x, Bandit, Phoenix HTML, LiveDashboard.
- Persistence: Ecto SQL 3.13 + Postgrex; PostgreSQL 17 Alpine in Compose. Tests use Ecto SQL Sandbox.
- Frontend: Tailwind CSS 4.3.0, daisyUI 5.5.20, esbuild 0.25.4, Heroicons 2.2.0. Assets are built by Mix wrappers; no separate npm workflow.
- Auth/security: invitation-based registration, Argon2 password hashing, database-backed session tokens, admin sudo reauthentication.
- Realtime/background: Phoenix PubSub/Presence, OTP supervisors/GenServers, database outbox, Web Push via web_push_elixir.
- HTTP client policy: Req only if outbound HTTP is needed; do not add HTTPoison, Tesla, or `:httpc`.
- Packaging: multi-stage Dockerfile with development and minimal production release targets; Docker Compose is the supported runtime/build interface.
- Production `mix assets.deploy` enforces gzip budgets: JavaScript <=55 KiB, CSS <=20 KiB.