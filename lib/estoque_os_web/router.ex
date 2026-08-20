defmodule EstoqueOSWeb.Router do
  use EstoqueOSWeb, :router

  import EstoqueOSWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EstoqueOSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_csp
    plug :fetch_current_scope_for_user
  end

  # The theme script in the root layout has to run before first paint, or the
  # screen flashes light before going dark, so it cannot move into app.js. That
  # rules out a policy without inline scripts — hence a per-request nonce rather
  # than `unsafe-inline`, which would permit every injected script equally.
  #
  # Styles keep `unsafe-inline`: Tailwind ships as a file, but DaisyUI and
  # LiveView both set `style` attributes, and those are covered by the same
  # directive.
  defp put_csp(conn, _opts) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode64()

    policy =
      [
        "default-src 'self'",
        "base-uri 'self'",
        "frame-ancestors 'none'",
        "object-src 'none'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "style-src 'self' 'unsafe-inline'",
        "script-src 'self' 'nonce-#{nonce}'",
        # LiveView's own socket. Same origin, but the scheme differs.
        "connect-src 'self' ws: wss:"
      ]
      |> Enum.join("; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_secure_browser_headers(%{"content-security-policy" => policy})
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EstoqueOSWeb do
    pipe_through :browser
  end

  # Other scopes may use custom stacks.
  # scope "/api", EstoqueOSWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:estoque_os, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EstoqueOSWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  # Anything that writes to the ledger. A viewer may read the stock; a viewer
  # may not send a mission's supplies out of the warehouse.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user, :require_operator]

    # The hands-on flows: what the person holding the boxes does. Logistics is
    # here because counting, loading out and receiving a return *is* their job.
    live_session :operational,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager logistics)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/stock/spreadsheet", StockLive.Spreadsheet, :new
      live "/entry", EntryLive.New, :new
      live "/conferences", ConferenceLive.Index, :index
      live "/audit", AuditLive.Index, :index
      live "/audit/:id", AuditLive.Count, :count
      live "/returns", ReturnLive.Index, :index
      live "/load-out", LoadOutLive.Index, :index
    end

    # Screens whose whole subject is money. An invoice is a document of prices,
    # and a donation certificate declares a value to a hospital — neither is
    # something a partner outside the ONG has any business opening.
    live_session :money,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/invoices/import", InvoiceLive.Import, :new
      live "/issue", IssueLive.Index, :index
    end

    # on_mount never runs for controllers, so these carry their own plugs. The
    # export is trimmed rather than refused (see `StockController.export/2`);
    # the certificate declares a value and is refused outright.
    pipe_through [:require_password_not_pending]
    get "/stock/export.xlsx", StockController, :export
  end

  scope "/", EstoqueOSWeb do
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_money,
      :require_password_not_pending
    ]

    get "/issues/:id/termo/:kind", CertificateController, :certificate
  end

  # Standing in another role's shoes. Guarded inside the controller rather than
  # by a pipeline, because leaving must work from *inside* a borrowed role — and
  # a borrowed role is not an admin.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/users/view-as", ViewAsController, :create
    delete "/users/view-as", ViewAsController, :delete
  end

  # Reading an invoice is reading a list of prices, so it sits behind the money
  # door rather than the writing one — the auditor belongs here and cannot
  # write, which is exactly the pair `require_operator` could not express.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user, :require_money]

    live_session :money_read,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager auditor)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/invoices", InvoiceLive.Index, :index
      live "/invoices/:id", InvoiceLive.Show, :show
    end
  end

  # Read-only: everyone who is signed in may look.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :signed_in,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/", HomeLive.Index, :index
      live "/stock", StockLive.Index, :index
      live "/boxes", BoxLive.Index, :index
      live "/boxes/:id", BoxLive.Show, :show
      live "/locations", LocationLive.Index, :index
      live "/kits", KitLive.Index, :index
      live "/kits/:id", KitLive.Show, :show
      live "/receipts/:id", ReceiptLive.Show, :show
      live "/issues", IssueLive.List, :index
      live "/reports/audit", AuditReportLive.Index, :index
      live "/missions", MissionLive.Index, :index
      live "/missions/:id", MissionLive.Show, :show
      live "/products/:id", ProductLive.Show, :show

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    # Deliberately NOT piped through `:require_password_not_pending` — this is
    # exactly the route the forced "required" page posts to, so it must stay
    # reachable while the flag is still set.
    post "/users/update-password", UserSessionController, :update_password
  end

  # Only a real admin (the effective, possibly-view-as-adjusted role) manages
  # who else gets an account.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user, :require_password_not_pending]

    live_session :admin,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/admin/users", UserLive.Index, :index
    end
  end

  # The forced first-login/first-reset password change. Its own live_session,
  # authenticated but deliberately NOT listing `:require_password_not_pending`
  # — this is the one screen that must stay open precisely while the flag is
  # set, which is why the gate is a router-level omission rather than a
  # per-view exception buried in the shared hook.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :reset_password_required,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, :current_path}
      ] do
      live "/users/reset-password/required", UserLive.ResetPassword, :required
    end
  end

  scope "/", EstoqueOSWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{EstoqueOSWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/users/reset-password", UserLive.ResetPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/reset-password/:token", UserSessionController, :create_from_reset_token
    delete "/users/log-out", UserSessionController, :delete
  end
end
