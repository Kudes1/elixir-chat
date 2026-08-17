# Commands

All normal project commands run through Docker Compose from the repository root.

- First setup/dev server: `cp .env.example .env && docker compose -f compose.yaml -f compose.dev.yaml up --build` (or `make dev-up`).
- Stop dev stack without deleting data: `make dev-down`.
- Dev logs: `make dev-logs`.
- Full tests: `make test`.
- Required pre-handoff checks: `make precommit`.
- Direct targeted test: `docker compose -f compose.yaml -f compose.dev.yaml exec web mix test test/path/to_test.exs`.
- Production stack: `make prod-up`, `make prod-logs`, `make prod-down`.
- Build production image only: `docker build --target production -t orbit:latest .`.
- Production admin lifecycle: `make admin-bootstrap LOGIN=alice NAME="Alice"`, `make admin-transfer LOGIN=alice`, `make admin-reset`.
- Dev admin CLI is a Mix task because `bin/orbit-admin` exists only in releases: `docker compose -f compose.yaml -f compose.dev.yaml exec web mix orbit.admin <bootstrap|transfer|reset> ...`.
- Never use `docker compose ... down -v` unless intentionally destroying PostgreSQL data and dependency/build caches.