defmodule EstoqueOSWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :estoque_os

  # Signed, not encrypted: contents are readable but tamper-proof.
  @session_options [
    store: :cookie,
    # The session and the 14-day remember-me cookie both carry a live session
    # token; neither may travel in the clear.
    secure: Mix.env() == :prod,
    key: "_estoque_os_key",
    signing_salt: "zV3rfe3q",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :estoque_os,
    gzip: not code_reloading?,
    only: EstoqueOSWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :estoque_os
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug EstoqueOSWeb.Router
end
