# syntax=docker/dockerfile:1
ARG ELIXIR_VERSION=1.19.1
ARG OTP_VERSION=27.3.4.3
ARG DEBIAN_VERSION=bookworm-20251117-slim
ARG ELIXIR_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${ELIXIR_IMAGE} AS base

RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git inotify-tools tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

FROM base AS builder

ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only $MIX_ENV && mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

RUN mix compile
COPY config/runtime.exs config/
RUN mix assets.deploy && mix release

FROM ${RUNNER_IMAGE} AS production

RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod \
    PHX_SERVER=true \
    LANG=C.UTF-8

COPY --from=builder /app/_build/prod/rel/elixir_chat ./
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh /app/bin/orbit-admin && chown -R nobody:nogroup /app

USER nobody
CMD ["/app/docker-entrypoint.sh"]
