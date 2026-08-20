#!/bin/sh
set -eu

mix deps.get
mix ecto.create --quiet
mix ecto.migrate --quiet
mix run e2e/seed.exs
exec mix phx.server
