import Config

config :estoque_os, EstoqueOS.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "estoque_os_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :estoque_os, EstoqueOSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "3RYOnMApSMMHSVwvB+RN6Qc4cFB50V/1Uy39by07QCC4VIcvz0YyzbVe5Ku0aHbV",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:estoque_os, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:estoque_os, ~w(--watch)]}
  ]

config :estoque_os, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Changing debug_heex_annotations needs `mix clean` + a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false

# The local adapter collects them at /dev/mailbox, so the email flows are
# worth having on while developing.
config :estoque_os, :email_enabled, true
