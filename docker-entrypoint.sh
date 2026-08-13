#!/bin/sh
set -eu

# `bin ... eval` starts the application to access Ecto. Keep the web endpoint
# disabled for these short-lived release tasks; it is enabled only for `start`.
unset PHX_SERVER

echo "Running database migrations..."
bin/elixir_chat eval "ElixirChat.Release.migrate()"

echo "Seeding initial workspace..."
bin/elixir_chat eval "ElixirChat.Release.seed()"

export PHX_SERVER=true
exec bin/elixir_chat start
