# Repository Guidelines

This project uses Elixir and Phoenix

## Code style
 - Write compact code.
 - Try to write in a style that allows the code to be reused.
 - Make sure the code is easy to review.
 - The code must be unambiguous. It is implied that the code should do a specific thing; everything else is discarded.

## Tool usage
 - Use MCP Context if it is available.
 - Use the MCP and LSP server serena if it is available.
 

## Docker-first workflow

The application **must be built and run with Docker Compose**. Do not rely on a host Elixir, Node, or PostgreSQL installation for normal development or verification.

```sh
cp .env.example .env
docker compose -f compose.yaml -f compose.dev.yaml up --build
```

`compose.yaml` is the production stack; `compose.dev.yaml` overlays it for local
development (hot reload, bind mounts). Use `docker compose -f compose.yaml -f compose.dev.yaml exec web mix test`
for tests and `docker compose -f compose.yaml -f compose.dev.yaml exec web mix precommit`
before handing off changes. `make dev-up`, `make test` and `make precommit` wrap
the same commands. Stop services with `docker compose -f compose.yaml -f compose.dev.yaml down`;
use `down -v` only when intentionally deleting local database data. Keep `Dockerfile`,
`compose.yaml`, `compose.dev.yaml`, and `.env.example` in sync with runtime configuration.

## Phoenix and LiveView

- LiveView templates must start with `<Layouts.app flash={@flash} current_scope={@current_scope}>` as appropriate. If `current_scope` is missing, move the route into the correct `live_session` and pass the assign.
- Use `<.icon>` from `core_components.ex`, `<.input>` for form controls, and `<.form for={@form}>` with a form created by `to_form/2`. Give key forms and controls unique DOM IDs.
- Use `~H`/`.html.heex`, never `~E`. Use `{...}` for attribute interpolation; use `<%= ... %>` for block constructs in tag bodies. Use `cond`/`case`, not `else if`.
- Use `push_navigate`/`push_patch` and `<.link navigate>`/`<.link patch>`; do not use deprecated LiveView navigation helpers.
- Prefer LiveView streams for dynamic collections. A streamed parent needs `id` and `phx-update="stream"`; reset streams after filtering. Do not enumerate streams or use `phx-update="append"`/`"prepend"`.
- JS hooks require an ID. Hooks managing their own DOM also require `phx-update="ignore"`. Use colocated hooks or files under `assets/js`; never add raw inline script tags to HEEx.

## Elixir, Ecto, and tests

- Keep one module per file. Use `Enum.at/2` or pattern matching for list indexing. Do not call `String.to_atom/1` on user input.
- Do not access structs with `struct[:field]`; access fields directly, or use `Ecto.Changeset.get_field/2` for changesets. Set server-controlled fields such as `user_id` explicitly, outside `cast`.
- Preload associations used by templates. Generate migrations with `mix ecto.gen.migration name_using_underscores`.
- Start test processes with `start_supervised!/1`. Synchronize with monitors or `:sys.get_state/1`, never `Process.sleep/1`.
- Use `Phoenix.LiveViewTest`, `LazyHTML`, and stable element IDs; assert elements and outcomes rather than raw HTML or fragile text.

## Assets and quality

- Use Tailwind utility classes and custom CSS; do not use `@apply`. Preserve the Tailwind v4 `@import` and `@source` directives in `assets/css/app.css`.
- Import frontend dependencies through `assets/js/app.js` or `assets/css/app.css`; do not add external `script` or stylesheet tags to layouts.
- Use `Req` for HTTP requests; do not add `HTTPoison`, Tesla, or `:httpc`.
- Run `mix precommit` (inside the Compose web service) after all changes and fix every reported issue.
