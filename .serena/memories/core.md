# Orbit project map

- Self-hosted team chat; Phoenix/LiveView monolith backed by PostgreSQL. Current deployment model: one application instance + one PostgreSQL.
- Domain contexts:
  - `lib/elixir_chat/accounts.ex`: invitations, sessions, users/admin lifecycle, auth-related audit events.
  - `lib/elixir_chat/chat.ex`: public/group channels, direct conversations, memberships, messages, cursor pagination, durable read cursors.
  - `lib/elixir_chat/notifications.ex`: browser Web Push preferences/subscriptions.
- Web boundary: `lib/elixir_chat_web/`; authenticated chat lives at `/channels/:public_id` and `/direct/:public_id`; admin UI requires authenticated admin plus sudo reauthentication.
- Runtime supervision: Repo, telemetry, DNSCluster hook, realtime supervision, durable outbox dispatcher, notification sender. Committed message events are stored in an outbox and published with at-least-once semantics. Web Push fan-out creates durable per-subscription `push_deliveries`; the sender polls them with bounded concurrency and persisted retry state.
- A Web Push endpoint has exactly one user owner and is transferred atomically on browser account changes. Endpoint hosts must match `WEB_PUSH_ALLOWED_HOST_SUFFIXES`; delivery revalidates the endpoint and Req redirects are globally disabled to prevent SSRF.
- Realtime uses Phoenix PubSub/Presence. `OnlineUsers` is a node-local ETS projection of Presence state.
- Persistent schemas/migrations: `lib/elixir_chat/{accounts,chat,notifications}/` and `priv/repo/migrations/`. Tests mirror contexts under `test/elixir_chat/` and web behavior under `test/elixir_chat_web/`.
- Invitation output is deliberately a host-independent `/invitation/TOKEN` path; reverse proxy owns public-domain allowlisting/TLS and must overwrite forwarded host/proto/port.
- Development and verification are Docker Compose only; never assume host Elixir, Node, or PostgreSQL.
- Read stack/version details in `mem:tech_stack`, runnable workflows in `mem:suggested_commands`, code rules in `mem:conventions`, and handoff gates in `mem:task_completion`.