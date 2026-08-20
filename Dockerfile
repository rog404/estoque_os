# Pinned to the exact Elixir and Erlang the test suite runs on — see
# `.tool-versions` and the versions CI installs. A deployment compiled against a
# different compiler than the tests is a deployment nothing has tested.
#
# Both images below publish amd64 and arm64, so this builds unchanged on an
# ordinary x86 host and on ARM (Oracle Ampere, Graviton, an Apple laptop).
ARG BUILDER_IMAGE="hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim"
ARG RUNNER_IMAGE="debian:trixie-20260713-slim"

FROM ${BUILDER_IMAGE} AS builder

# git: two dependencies (heroicons, daisyui) are sparse git checkouts.
# curl: `mix assets.setup` downloads the tailwind and esbuild binaries.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, and compiled before any application code is copied, so
# editing a LiveView does not recompile the world on the next build.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

COPY config/runtime.exs config/
COPY rel rel

# The release builds and digests its own assets — see the `:assets` step in
# mix.exs. That is why there is no Node stage here and no `npm install`.
RUN mix release

# ---------------------------------------------------------------------------

FROM ${RUNNER_IMAGE}

# ca-certificates is not optional: the database connection verifies the
# server's certificate against the system trust store
# (`:public_key.cacerts_get()`), and without this package that call returns
# nothing and every connection fails with a TLS error that reads like a
# firewall problem.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# C.UTF-8 is built into glibc, so this needs no `locales` package and no
# locale-gen. The BEAM only needs *a* UTF-8 locale; the interface language is
# Gettext's business, not the operating system's.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV="prod" \
    PHX_SERVER="true"

WORKDIR /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/estoque_os ./
COPY --chown=nobody:root rel/entrypoint.sh /app/entrypoint.sh

USER nobody

# Migrations run before the web server starts, in the same command, so a deploy
# that cannot migrate never comes up serving the old schema.
CMD ["/app/entrypoint.sh"]
