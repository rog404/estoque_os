import Config

config :estoque_os, EstoqueOSWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# force_ssl (with HSTS) must be set at compile-time.
config :estoque_os, EstoqueOSWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

config :swoosh, api_client: Swoosh.ApiClient.Req
config :swoosh, local: false
config :logger, level: :info
