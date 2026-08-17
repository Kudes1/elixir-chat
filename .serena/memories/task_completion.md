# Task completion gates

- Build/run/verify through the Compose development stack; do not use host Elixir, Node, or PostgreSQL.
- During implementation, run the narrow relevant tests inside `web`, e.g. `docker compose -f compose.yaml -f compose.dev.yaml exec web mix test test/path/to_test.exs`.
- Before handoff, run exactly `docker compose -f compose.yaml -f compose.dev.yaml exec web mix precommit` (equivalent: `make precommit`).
- `mix precommit` compiles with warnings as errors, removes unused dependency locks, formats source, and runs the entire test suite. Fix every reported issue.
- If runtime configuration changes, keep `Dockerfile`, `compose.yaml`, `compose.dev.yaml`, and `.env.example` synchronized.
- If production assets change, ensure `mix assets.deploy` still passes the gzip budgets (JS 55 KiB, CSS 20 KiB).
- Never tear down with `down -v` as routine cleanup; it destroys local database data and caches.