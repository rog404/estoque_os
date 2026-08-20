import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/estoque_os start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :estoque_os, EstoqueOSWeb.Endpoint, server: true
end

config :estoque_os, EstoqueOSWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :estoque_os, EstoqueOSWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/estoque_os_web/router\.ex$"E,
        ~r"lib/estoque_os_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  database_host = database_url |> URI.parse() |> Map.fetch!(:host)

  # Encrypted always. Verified against the host's own certificate by default,
  # which is the only version of TLS that means anything — an unverified
  # connection is an encrypted conversation with whoever answered.
  #
  # The escape hatch exists because managed Postgres is often presented behind
  # a private certificate authority that is not in the system store, and the
  # symptom is a deploy that cannot reach its database at all. Two ways out,
  # in order of preference: point DATABASE_CA_CERT_FILE at the provider's CA
  # bundle, or — knowing what it costs, and it is logged on every boot —
  # DATABASE_SSL_VERIFY=none.
  ssl_opts =
    case {System.get_env("DATABASE_SSL_VERIFY"), System.get_env("DATABASE_CA_CERT_FILE")} do
      {"none", _} ->
        IO.warn("""
        DATABASE_SSL_VERIFY=none: the database connection is encrypted but the \
        server's certificate is not being checked. Set DATABASE_CA_CERT_FILE to \
        the provider's CA bundle instead as soon as you have it.
        """)

        [verify: :verify_none]

      {_, nil} ->
        [verify: :verify_peer, cacerts: :public_key.cacerts_get()]

      {_, path} ->
        [verify: :verify_peer, cacertfile: path]
    end

  # Off only for smoke-testing the built release against a local Postgres, which
  # does not speak TLS. Never for a real deployment — hence the shout.
  database_ssl? = System.get_env("DATABASE_SSL") not in ~w(false 0)

  if not database_ssl? do
    IO.warn("DATABASE_SSL=false: connecting to the database in the clear.")
  end

  config :estoque_os, EstoqueOS.Repo,
    ssl: database_ssl?,
    ssl_opts:
      ssl_opts ++
        [
          server_name_indication: to_charlist(database_host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
    url: database_url,
    # Two, because the free-tier database allows two connections in total and
    # the deploy needs one of them for the migration. Raise it with the plan,
    # not before: a pool larger than the database permits fails as a timeout
    # under load, which reads like a slow query rather than a misconfiguration.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "2"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # RENDER_EXTERNAL_HOSTNAME is set by Render to this service's own hostname.
  # Reading it means one fewer thing to configure by hand, and it removes the
  # classic misconfiguration: a wrong host makes `check_origin` refuse the
  # LiveView socket, so every page renders once and then never updates —
  # which looks like a broken app rather than a wrong variable. PHX_HOST still
  # wins when set, for a custom domain or another platform.
  host =
    System.get_env("PHX_HOST") || System.get_env("RENDER_EXTERNAL_HOSTNAME") ||
      "example.com"

  config :estoque_os, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :estoque_os, EstoqueOSWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :estoque_os, EstoqueOSWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :estoque_os, EstoqueOSWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## The mailer
  #
  # Deliberately not configured, and `:email_enabled` stays false here (see
  # `EstoqueOS.Accounts.email_enabled?/0`). Accounts are handed out by an
  # administrator with a temporary password, so nothing about getting in
  # depends on a message arriving, and the deployment needs no sending domain
  # and no outbound provider.
  #
  # To turn it on: set `EMAIL_ENABLED=true` alongside an adapter, e.g.
  #
  #     config :estoque_os, :email_enabled, true
  #
  #     config :estoque_os, EstoqueOS.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # `config/prod.exs` already sets `Swoosh.ApiClient.Req`, which every non-SMTP
  # adapter needs.
  if System.get_env("EMAIL_ENABLED") in ~w(true 1) do
    config :estoque_os, :email_enabled, true
  end

  # Letterhead for the donation certificates. `config/config.exs` ships
  # placeholders on purpose — a public repository is the wrong place for the
  # registration number that goes on a document handed to a hospital.
  organization = Application.get_env(:estoque_os, :organization, [])

  config :estoque_os, :organization,
    name: System.get_env("ORGANIZATION_NAME") || Keyword.fetch!(organization, :name),
    document: System.get_env("ORGANIZATION_DOCUMENT") || Keyword.fetch!(organization, :document),
    address: System.get_env("ORGANIZATION_ADDRESS") || Keyword.fetch!(organization, :address),
    contact: System.get_env("ORGANIZATION_CONTACT") || Keyword.fetch!(organization, :contact)
end
