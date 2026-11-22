import Config

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

  # Always encrypted; DATABASE_SSL_VERIFY chooses what the server's certificate
  # must prove: verify-full (default: real chain and matching host), "ca" (real
  # chain, host not checked — a private endpoint whose cert omits the internal
  # name), or "none" (encrypted, cert unchecked). Render's internal Postgres
  # answers with a self-signed cert, so only "none" connects there — see
  # render.yaml.
  trust_store = fn
    nil -> [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    path -> [verify: :verify_peer, cacertfile: path]
  end

  hostname_check = [
    server_name_indication: to_charlist(database_host),
    customize_hostname_check: [
      match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    ]
  ]

  ssl_opts =
    case {System.get_env("DATABASE_SSL_VERIFY"), System.get_env("DATABASE_CA_CERT_FILE")} do
      {"none", _} ->
        # Not IO.warn: its stacktrace would read as a crash on every boot.
        IO.puts(
          :stderr,
          "DATABASE_SSL_VERIFY=none: the database connection is encrypted but " <>
            "the server's certificate is not being checked at all. Only sound " <>
            "over a private network you trust — see render.yaml."
        )

        [verify: :verify_none]

      {"ca", cert_file} ->
        IO.puts(
          "DATABASE_SSL_VERIFY=ca: the certificate chain is verified; " <>
            "the hostname is not (private network endpoint)."
        )

        trust_store.(cert_file) ++
          [
            server_name_indication: to_charlist(database_host),
            # Accept any hostname; the chain was already required to be real.
            customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
          ]

      {_, cert_file} ->
        trust_store.(cert_file) ++ hostname_check
    end

  # Off only for smoke-testing the built release against a local Postgres, which
  # does not speak TLS. Never for a real deployment — hence the shout.
  database_ssl? = System.get_env("DATABASE_SSL") not in ~w(false 0)

  if not database_ssl? do
    IO.warn("DATABASE_SSL=false: connecting to the database in the clear.")
  end

  config :estoque_os, EstoqueOS.Repo,
    # Options go in `:ssl` (Postgrex deprecated the separate `:ssl_opts`).
    ssl: database_ssl? && ssl_opts,
    url: database_url,
    # Two: the free-tier database allows two connections, one of which the
    # deploy's migration needs. Raise it with the plan.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "2"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Default to Render's own hostname: a wrong host makes check_origin refuse the
  # LiveView socket, so pages render once and never update. PHX_HOST overrides.
  host =
    System.get_env("PHX_HOST") || System.get_env("RENDER_EXTERNAL_HOSTNAME") ||
      "example.com"

  config :estoque_os, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :estoque_os, EstoqueOSWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  # Mailer off by default (see EstoqueOS.Accounts.email_enabled?/0): accounts are
  # handed out with a temporary password, so login needs no mail. To enable, set
  # EMAIL_ENABLED=true and configure an adapter on EstoqueOS.Mailer.
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
    contact: System.get_env("ORGANIZATION_CONTACT") || Keyword.fetch!(organization, :contact),
    tax_note: System.get_env("ORGANIZATION_TAX_NOTE") || Keyword.fetch!(organization, :tax_note)
end
