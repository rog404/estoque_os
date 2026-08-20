#!/bin/sh
# Migrate, then serve. One command, in that order, so a deploy that cannot
# migrate never comes up answering requests against the old schema.
#
# `set -e` is what makes the order meaningful: if the migration fails the
# container exits and the platform reports a failed deploy, instead of a healthy
# service quietly running the wrong code.
set -e

/app/bin/estoque_os eval "EstoqueOS.Release.migrate()"

# Only does anything when SEED_ON_EMPTY is set and the database has no accounts
# — which is true exactly once. The free plans these demos run on give you no
# shell, so there is no other moment to load the data in.
/app/bin/estoque_os eval "EstoqueOS.Release.seed_if_empty()"

exec /app/bin/estoque_os start
