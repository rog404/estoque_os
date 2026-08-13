defmodule EstoqueOSWeb.UserAuth do
  use EstoqueOSWeb, :verified_routes
  use Gettext, backend: EstoqueOSWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias EstoqueOS.Accounts
  alias EstoqueOS.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_estoque_os_web_user_remember_me"
  @remember_me_options [
    sign: true,
    secure: Mix.env() == :prod,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      EstoqueOSWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, scope_with_view_as(user, get_session(conn, :view_as)))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      EstoqueOSWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule EstoqueOSWeb.PageLive do
        use EstoqueOSWeb, :live_view

        on_mount {EstoqueOSWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{EstoqueOSWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      # Assigned here rather than beside `@writable?`, because every live_session
      # mounts this one and only some mount `:guard_writes`. A screen that asked
      # `@sees_money?` from the wrong session would raise in production and
      # render the price in the meantime; from here the answer always exists.
      {:cont,
       Phoenix.Component.assign(socket, :sees_money?, sees_money?(socket.assigns.current_scope))}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, gettext("You must log in to access this page."))
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  # The navigation marks where you are, which means the layout needs the path.
  # LiveView only knows it per handle_params, so we keep it on the socket.
  def on_mount(:current_path, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :save_current_path, :handle_params, fn
       _params, uri, socket ->
         {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
     end)}
  end

  @doc false
  # Screens that report to everyone still carry buttons that write: a box is
  # moved from the box screen, a kit is packed from the kit screen. The route is
  # the wrong gate for those — blocking it would take the reporting away from the
  # people it is for — so the gate is the event.
  #
  # Default-deny, and deliberately so. A LiveView lists the events a viewer may
  # send; anything else is refused. The inverse — listing the writes — fails open
  # the day somebody adds a handler and forgets the list, which is exactly how
  # this hole appeared in the first place.
  def on_mount(:guard_writes, _params, _session, socket) do
    # Two questions, and they used to be one. `@role_may_write?` decides whether
    # the control exists on this screen at all; `@writable?` decides whether this
    # session may press it, and the hook refuses the event either way. Deriving
    # all of it from here is what stops a hidden button and an open handler
    # drifting apart.
    scope = socket.assigns[:current_scope]

    socket =
      socket
      |> Phoenix.Component.assign(:writable?, operator?(scope))
      |> Phoenix.Component.assign(:role_may_write?, role_may_write?(scope))
      |> Phoenix.Component.assign(:write_block, write_block(scope))

    {:cont,
     Phoenix.LiveView.attach_hook(socket, :guard_writes, :handle_event, fn
       event, _params, socket ->
         if operator?(socket.assigns[:current_scope]) or event in viewer_events(socket.view) do
           {:cont, socket}
         else
           {:halt,
            Phoenix.LiveView.put_flash(
              socket,
              :error,
              gettext("You don't have permission to do that.")
            )}
         end
     end)}
  end

  def on_mount({:require_role, allowed_roles}, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %Accounts.User{}} = scope ->
        role = Scope.effective_role(scope)

        if role in allowed_roles do
          {:cont, socket}
        else
          socket =
            socket
            |> Phoenix.LiveView.put_flash(
              :error,
              gettext("You don't have permission to access this page.")
            )
            |> Phoenix.LiveView.redirect(to: ~p"/")

          {:halt, socket}
        end

      _ ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, gettext("You must log in to access this page."))
          |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

        {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          gettext("You must re-authenticate to access this page.")
        )
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  defp viewer_events(view) do
    if Code.ensure_loaded?(view) and function_exported?(view, :viewer_events, 0) do
      view.viewer_events()
    else
      []
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      scope_with_view_as(user, session["view_as"])
    end)
  end

  defp scope_with_view_as(user, nil), do: Scope.for_user(user)

  defp scope_with_view_as(user, role) do
    user |> Scope.for_user() |> Scope.viewing_as(role)
  end

  @doc "Returns the path to redirect to after log in."
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Whether this scope may write to the ledger.

  The plug and the `on_mount` gate whole routes. This answers the same question
  inside a page that a reader is allowed to open but not to write from — the
  stock screen, which reports to everyone and imports counts from the people who
  handle the boxes.
  """
  def operator?(%Scope{} = scope) do
    # Read-only, always. An admin standing in the logistics operator's shoes is
    # there to see what that person sees; letting them post a transaction would
    # write somebody else's role into a ledger that records who did what.
    not Scope.viewing_as?(scope) and
      Scope.effective_role(scope) in Accounts.User.roles_that_write()
  end

  def operator?(_scope), do: false

  @doc """
  Whether the role being *shown* writes here — which is a different question
  from whether this session may press the button.

  A hidden button teaches nothing. An admin who steps into the logistics
  operator's shoes to see what that person sees was getting a hollow copy of
  every screen: the route opened, the page rendered, and every control that
  made the page worth visiting was gone. You could not tell a permission you
  lack from a feature that does not exist from a bug.

  So the control is rendered, and disabled, with `write_block/1` saying why.
  The refusal itself does not move: `operator?/1` still says no, the event hook
  still refuses, and an admin standing in somebody else's shoes still cannot
  post a transaction.
  """
  def role_may_write?(%Scope{} = scope),
    do: Scope.effective_role(scope) in Accounts.User.roles_that_write()

  def role_may_write?(_scope), do: false

  @doc """
  Why the controls on this screen are disabled, or `nil` when they are not.

  Only one reason exists today, and it is the one worth saying out loud: you
  are borrowing a role. A reader who never had the button does not reach this —
  `role_may_write?/1` has already removed it.
  """
  def write_block(%Scope{} = scope) do
    if role_may_write?(scope) and not operator?(scope) do
      gettext("You are seeing the app as another role. Nothing here can be recorded.")
    end
  end

  def write_block(_scope), do: nil

  @doc """
  Whether this scope may see what anything cost.

  A separate question from `operator?/1`, and deliberately not a rung on the
  same ladder: the logistics operator writes and must not see prices, the
  auditor sees prices and must not write. Ordering the roles by "power" cannot
  express that, so there are two predicates and each screen asks the one it
  means.

  This is not a display preference. Where it says no, the number must never be
  rendered — hiding it in markup still ships it to the browser, and the whole
  point is that a partner outside the ONG does not receive the ONG's purchase
  prices.
  """
  def sees_money?(%Scope{} = scope),
    do: Scope.effective_role(scope) in Accounts.User.roles_that_see_money()

  def sees_money?(_scope), do: false

  @doc """
  Plug for controller routes that write or export. `on_mount` never runs for a
  controller, so the two `get` routes need their own gate.
  """
  def require_operator(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{}} = scope ->
        if operator?(scope), do: conn, else: refuse(conn)

      _ ->
        refuse(conn)
    end
  end

  @doc """
  Plug for controller routes whose content is money. Same shape as
  `require_operator/2`, different question — the donation certificate declares a
  value and is not for the logistics partner, however much they may write.
  """
  def require_money(conn, _opts) do
    if sees_money?(conn.assigns[:current_scope]), do: conn, else: refuse(conn)
  end

  defp refuse(conn) do
    conn
    |> put_flash(:error, gettext("You don't have permission to access this page."))
    |> redirect(to: ~p"/")
    |> halt()
  end

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, gettext("You must log in to access this page."))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
