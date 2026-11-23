defmodule EstoqueOSWeb.UserAuth do
  use EstoqueOSWeb, :verified_routes
  use Gettext, backend: EstoqueOSWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias EstoqueOS.Accounts
  alias EstoqueOS.Accounts.Scope

  # Must match the session validity in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_estoque_os_web_user_remember_me"
  @remember_me_options [
    sign: true,
    secure: Mix.env() == :prod,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # Age at which a session token is reissued. Above `@max_cookie_age_in_days`
  # disables reissuing.
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

  # Creating a session clears it via renew_session to avoid fixation attacks.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Not renewed if already logged in: avoids CSRF errors and lost data in open tabs.
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # Renews the session ID and erases the session to avoid fixation attacks.
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

    * `:mount_current_scope` - assigns current_scope, nil if no valid token.
    * `:require_authenticated` - same, redirecting to login if there is no user.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      # Assigned here, not beside `@writable?`: every live_session mounts this
      # clause but only some mount `:guard_writes`, and `@sees_money?` must always exist.
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

  # The layout marks the current nav entry; LiveView only knows the path per handle_params.
  def on_mount(:current_path, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :save_current_path, :handle_params, fn
       _params, uri, socket ->
         {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
     end)}
  end

  @doc false
  # Read-only screens still carry write buttons, so the gate is the event, not
  # the route. Default-deny: a LiveView lists the events a viewer may send
  # (`viewer_events/0`); listing the writes instead fails open when a handler
  # is added and the list forgotten.
  def on_mount(:guard_writes, _params, _session, socket) do
    # Three assigns:
    #   * `@role_may_write?` - the shown role writes here at all; false removes the markup.
    #   * `@controls_enabled?` - controls look usable, so view-as shows the real app.
    #   * `@writable?` - this session may actually write; false while viewing as.
    scope = socket.assigns[:current_scope]

    socket =
      socket
      |> Phoenix.Component.assign(:writable?, operator?(scope))
      |> Phoenix.Component.assign(:controls_enabled?, controls_enabled?(scope))
      |> Phoenix.Component.assign(:role_may_write?, role_may_write?(scope))

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

  @doc false
  # A temporary or just-reset password blocks everything until replaced. Its own
  # clause, so the router stays the one place saying which routes skip it.
  def on_mount(:require_password_not_pending, _params, _session, socket) do
    if socket.assigns.current_scope.user.must_reset_password do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/reset-password/required")}
    else
      {:cont, socket}
    end
  end

  @doc false
  # Guards flows that need an email to arrive; there may or may not be a user.
  def on_mount(:require_email_enabled, _params, _session, socket) do
    if EstoqueOS.Accounts.email_enabled?() do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, email_disabled_message())
       |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")}
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

  # Read from the token every time, not `assign_new`: a live navigation reuses
  # the socket, so `assign_new` would check the token once and keep an expired
  # or remotely deleted session alive. Costs one query per navigation.
  defp mount_current_scope(socket, session) do
    {user, _} =
      if user_token = session["user_token"] do
        Accounts.get_user_by_session_token(user_token)
      end || {nil, nil}

    Phoenix.Component.assign(socket, :current_scope, scope_with_view_as(user, session["view_as"]))
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
  Whether this scope may write to the ledger. The plug and `on_mount` gate
  whole routes; this answers it inside a page a reader may open.
  """
  def operator?(%Scope{} = scope) do
    # Always false while viewing as: the ledger records who did what.
    not Scope.viewing_as?(scope) and
      Scope.effective_role(scope) in Accounts.User.roles_that_write()
  end

  def operator?(_scope), do: false

  @doc """
  Whether the role being *shown* writes here, as opposed to whether this session
  may press the button.

  Controls are rendered usable under view-as, so the admin sees the real app;
  the refusal stays in `operator?/1` and the event hook.
  """
  def role_may_write?(%Scope{} = scope),
    do: Scope.effective_role(scope) in Accounts.User.roles_that_write()

  def role_may_write?(_scope), do: false

  @doc """
  Whether the controls are drawn as usable: for the role that writes here,
  including an admin borrowing it. Refusal happens on the way in, not in looks.
  """
  def controls_enabled?(%Scope{} = scope), do: role_may_write?(scope)
  def controls_enabled?(_scope), do: false

  @doc """
  Whether this scope may see what anything cost.

  Separate from `operator?/1`, not a rung on one ladder: logistics writes but
  must not see prices; the auditor sees prices but must not write.

  Where it says no, the number must never be rendered: hiding it in markup
  still ships it to the browser.
  """
  def sees_money?(%Scope{} = scope),
    do: Scope.effective_role(scope) in Accounts.User.roles_that_see_money()

  def sees_money?(_scope), do: false

  @doc """
  Plug for the routes that write, and for the export.

  Asks `role_may_write?/1`, not `operator?/1`, so view-as can open the borrowed
  role's screens. Nothing is loosened: every `live_session` behind it mounts
  `:guard_writes`, and `operator?/1` stays false while viewing as.
  """
  def require_operator(conn, _opts) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{}} = scope ->
        if role_may_write?(scope), do: conn, else: refuse(conn)

      _ ->
        refuse(conn)
    end
  end

  @doc """
  Plug for controller routes whose content is money; same shape as
  `require_operator/2`, different question.
  """
  def require_money(conn, _opts) do
    if sees_money?(conn.assigns[:current_scope]), do: conn, else: refuse(conn)
  end

  @doc """
  Plug equivalent of the `:require_password_not_pending` on_mount clause, for
  controller routes. Not used on the reset-password routes themselves.
  """
  def require_password_not_pending(conn, _opts) do
    if conn.assigns.current_scope.user.must_reset_password do
      conn
      |> put_flash(:error, gettext("You must set a new password before continuing."))
      |> redirect(to: ~p"/users/reset-password/required")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Plug equivalent of the `:require_email_enabled` on_mount clause, for the
  controller routes in the same scope.
  """
  def require_email_enabled(conn, _opts) do
    if EstoqueOS.Accounts.email_enabled?() do
      conn
    else
      conn
      |> put_flash(:error, email_disabled_message())
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp email_disabled_message do
    gettext(
      "This installation does not send email. Log in with your password, or ask an administrator to reset it."
    )
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
