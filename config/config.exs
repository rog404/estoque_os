# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :estoque_os, :scopes,
  user: [
    default: true,
    module: EstoqueOS.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: EstoqueOS.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :estoque_os,
  namespace: EstoqueOS,
  ecto_repos: [EstoqueOS.Repo],
  generators: [timestamp_type: :utc_datetime]

# Letterhead data printed on the donation certificates.
config :estoque_os, :organization,
  name: "Operação Sorriso do Brasil",
  document: "00.000.000/0000-00",
  address: "São Paulo — SP",
  contact: "contato@exemplo.org"

# How many days ahead the dashboard warns about expiring stock. Individual
# products may override it.
config :estoque_os, :expiry_alert_days, 90

# Location the invoice import screen preselects as the receiving warehouse.
config :estoque_os, :default_location_name, "Estoque Principal"

# All user-facing content is Brazilian Portuguese; English is kept as the
# source language of the msgids only.
config :estoque_os, EstoqueOSWeb.Gettext,
  default_locale: "pt_BR",
  locales: ~w(pt_BR)

# Configure the endpoint
config :estoque_os, EstoqueOSWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EstoqueOSWeb.ErrorHTML, json: EstoqueOSWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EstoqueOS.PubSub,
  live_view: [signing_salt: "GZQOPeuC"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :estoque_os, EstoqueOS.Mailer, adapter: Swoosh.Adapters.Local

# Off by default, and prod leaves it off: accounts are handed out by an
# administrator, so no login path needs a message to arrive. `dev` and `test`
# turn it on to exercise the flows that do use email. See
# `EstoqueOS.Accounts.email_enabled?/0`.
config :estoque_os, :email_enabled, false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  estoque_os: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  estoque_os: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The ledger is UTC throughout; screens render it in São Paulo time.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
