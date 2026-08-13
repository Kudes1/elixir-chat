#!/bin/sh
set -eu

if [ "${1:-}" = "mix" ] && { [ "${2:-}" = "test" ] || [ "${2:-}" = "precommit" ]; }; then
  exec "$@"
fi

mix deps.get
mix ecto.create --quiet
mix ecto.migrate
mix run priv/repo/seeds.exs

exec "$@"
