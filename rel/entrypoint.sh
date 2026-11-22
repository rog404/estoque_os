#!/bin/sh
# Migrate, then serve, in that order with set -e: a deploy that cannot migrate
# exits and fails instead of serving the old schema.
set -e

/app/bin/estoque_os eval "EstoqueOS.Release.migrate()"

# Seeds only when SEED_ON_EMPTY is set and the database has no accounts (true
# once): the free plan gives no shell to seed by hand.
/app/bin/estoque_os eval "EstoqueOS.Release.seed_if_empty()"

exec /app/bin/estoque_os start
