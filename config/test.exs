import Config

config :bcrypt_elixir, :log_rounds, 1

config :estoque_os, EstoqueOS.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("PGHOST", "localhost"),
  # This machine runs Postgres on 5433; a CI service container publishes the
  # default. Neither should have to know about the other.
  port: String.to_integer(System.get_env("PGPORT", "5433")),
  database: "estoque_os_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :estoque_os, EstoqueOSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ijrl+5y9kRMd4zpmGXP2KEjRXirs3lvdozqnrVDFJ9AxbXLR2GBzpQ0V/cf0t8xn",
  server: false

config :estoque_os, EstoqueOS.Mailer, adapter: Swoosh.Adapters.Test

# On, so the email flows stay tested even though production runs without them.
# `email_disabled_test.exs` flips it off for the other half.
config :estoque_os, :email_enabled, true

config :swoosh, :api_client, false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params so verified-route URLs compare equal regardless of order.
config :phoenix,
  sort_verified_routes_query_params: true
