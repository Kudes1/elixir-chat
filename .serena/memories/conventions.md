# Project conventions

- One Elixir module per file. Use direct struct fields, not `struct[:field]`; for changesets use `Ecto.Changeset.get_field/2`. Never atomize user input with `String.to_atom/1`. Use pattern matching or `Enum.at/2` for list access.
- Server-controlled fields (especially ownership/user IDs) are assigned explicitly outside `cast`. Preload every association consumed by templates.
- Generate migrations with underscore names via `mix ecto.gen.migration name_using_underscores`.
- LiveView templates start with `<Layouts.app flash={@flash} current_scope={@current_scope}>` as applicable; routes needing scope belong in the correct `live_session`.
- Forms use `to_form/2`, `<.form for={@form}>`, and `<.input>`; use `<.icon>` for icons. Important forms/controls have stable unique DOM IDs.
- HEEx only (`~H`/`.html.heex`): `{...}` in attributes, `<%= ... %>` for block constructs in bodies, and `cond`/`case` instead of “else if”.
- Navigation uses `push_navigate`/`push_patch` and `<.link navigate>`/`<.link patch>`.
- Dynamic collections prefer LiveView streams. Stream container requires an ID and `phx-update="stream"`; reset streams after filters. Do not enumerate streams or use append/prepend updates.
- JS hooks require an ID; hooks owning DOM also require `phx-update="ignore"`. Use colocated hooks or `assets/js`, never raw inline script tags.
- Tailwind utilities/custom CSS only; no `@apply`. Preserve Tailwind v4 `@import`/`@source` directives. Import frontend dependencies from `assets/js/app.js` or `assets/css/app.css`, not external layout tags.
- Tests use `Phoenix.LiveViewTest`, LazyHTML, stable element IDs, and outcome/element assertions. Start processes with `start_supervised!/1`; synchronize with monitors or `:sys.get_state/1`, never `Process.sleep/1`.