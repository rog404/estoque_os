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

  # The root layout's theme script must run before first paint, so inline scripts
  # stay: a per-request nonce, not `unsafe-inline`.
  # Styles keep `unsafe-inline`: DaisyUI and LiveView set `style` attributes.
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
        # LiveView's socket: same origin, different scheme.
        "connect-src 'self' ws: wss:"
      ]
      |> Enum.join("; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_secure_browser_headers(%{
      "content-security-policy" => policy,
      # `no-store` makes the back button a real request, so a logged-out person
      # cannot read a cached page.
      "cache-control" => "no-store, no-cache, must-revalidate, private",
      "pragma" => "no-cache"
    })
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EstoqueOSWeb do
    pipe_through :browser
  end

  # LiveDashboard and Swoosh mailbox preview, development only.
  if Application.compile_env(:estoque_os, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EstoqueOSWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Anything that writes to the ledger; viewers may only read.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user, :require_operator]

    # Hands-on flows. Logistics included: counting, loading out and receiving a
    # return is their job.
    # Marketing included: a mission box mixes marketing material and supplies.
    live_session :operational,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager logistics marketing)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/conferences", ConferenceLive.Index, :index
      live "/boxes/:id/count", BoxLive.Count, :count
      live "/returns", ReturnLive.Index, :index
      live "/load-out", LoadOutLive.Index, :index
      live "/shipments/:id/declaracao", ShipmentLive.Declaration, :edit
    end

    # Own session: marketing belongs in this flow but not in the :operational ones.
    live_session :manual_entry,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager logistics marketing)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/entry", EntryLive.New, :new
    end

    # Split from the invoice import: marketing sells from this screen but has no
    # business in a supplier's invoice.
    live_session :issuing,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager marketing)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/issue", IssueLive.Index, :index
    end

    # Spreadsheet import is a planning act, not hands-on: logistics is excluded.
    live_session :planning,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/stock/sheets", StockLive.Spreadsheet, :new
    end

    # Money screens (invoice prices, donation certificate values): closed to
    # partners outside the ONG.
    live_session :money,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager marketing)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/invoices/import", InvoiceLive.Import, :new
    end

    # on_mount never runs for controllers, so these carry their own plugs. The
    # export is trimmed rather than refused (see `StockController.export/2`).
    pipe_through [:require_password_not_pending]
    get "/stock/export.xlsx", StockController, :export
    get "/stock/count-sheet.xlsx", StockController, :count_sheet
    get "/stock/template.xlsx", StockController, :template
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

  # Printed declaration: a controller, since the page exists to become paper.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user, :require_password_not_pending]

    get "/shipments/:id/declaracao/imprimir", DeclarationController, :print
  end

  # View-as: guarded inside the controller, because leaving must work from a
  # borrowed role, which is not an admin.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/users/view-as", ViewAsController, :create
    delete "/users/view-as", ViewAsController, :delete
  end

  # Behind the money door, not the writing one: the auditor reads but cannot
  # write, which `require_operator` cannot express.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_authenticated_user, :require_money]

    live_session :money_read,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager marketing auditor)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/invoices", InvoiceLive.Index, :index
      live "/invoices/:id", InvoiceLive.Show, :show
      live "/reports/sales", SalesReportLive.Index, :index
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
      live "/issues", IssueLive.List, :index
      live "/entries", EntryLive.List, :index
      live "/products/:id", ProductLive.Show, :show

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    # Warehouse screens (boxes, kits, missions, audit). Marketing included: both
    # stocks share the warehouse, boxes and missions.
    live_session :warehouse_read,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :require_authenticated},
        {EstoqueOSWeb.UserAuth, {:require_role, ~w(admin manager logistics auditor marketing)}},
        {EstoqueOSWeb.UserAuth, :current_path},
        {EstoqueOSWeb.UserAuth, :guard_writes},
        {EstoqueOSWeb.UserAuth, :require_password_not_pending}
      ] do
      live "/boxes", BoxLive.Index, :index
      # Before `/boxes/:id`, or "lookup" is captured as an :id.
      live "/boxes/lookup", BoxLive.Lookup, :index
      live "/boxes/:id", BoxLive.Show, :show
      live "/locations", LocationLive.Index, :index
      live "/kits", KitLive.Index, :index
      live "/kits/:id", KitLive.Show, :show
      live "/receipts/:id", ReceiptLive.Show, :show
      live "/reports/audit", AuditReportLive.Index, :index
      live "/reports/transit", TransitLive.Index, :index
      live "/missions", MissionLive.Index, :index
      live "/missions/:id", MissionLive.Show, :show
    end

    # Deliberately NOT behind `:require_password_not_pending`: the forced
    # "required" page posts here while the flag is still set.
    post "/users/update-password", UserSessionController, :update_password
  end

  # Admin only (effective role, after view-as): manages accounts.
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

  # Forced password change: authenticated but deliberately NOT listing
  # `:require_password_not_pending`, since it must stay open while the flag is
  # set. The omission lives here, not as an exception in the shared hook.
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
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Flows that need an email to arrive (magic link, password reset). Without a
  # mailer they explain instead of showing a dead form; see
  # `EstoqueOS.Accounts.email_enabled?/0`.
  scope "/", EstoqueOSWeb do
    pipe_through [:browser, :require_email_enabled]

    live_session :email_flows,
      on_mount: [
        {EstoqueOSWeb.UserAuth, :mount_current_scope},
        {EstoqueOSWeb.UserAuth, :require_email_enabled}
      ] do
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/users/reset-password", UserLive.ResetPassword, :new
      live "/users/reset-password/:token", UserLive.ResetPassword, :edit
    end

    post "/users/reset-password/:token", UserSessionController, :create_from_reset_token
  end
end
