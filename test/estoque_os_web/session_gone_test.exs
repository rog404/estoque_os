defmodule EstoqueOSWeb.SessionGoneTest do
  @moduledoc """
  What a screen does once the session behind it is gone. Two cases:

    1. An already-open tab: a live navigation reruns `mount` on a socket that
       already carries `current_scope`, so reading it through `assign_new`
       would check the token only once, when the tab opened.

    2. The back button: a page restored from the browser cache is never
       re-checked with the server.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EstoqueOS.Accounts
  alias EstoqueOSWeb.UserAuth
  alias Phoenix.LiveView

  setup :register_and_log_in_operator

  describe "a session that died while the tab was open" do
    test "is not carried by a socket that already has a scope", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      session = conn |> Plug.Conn.put_session(:user_token, token) |> Plug.Conn.get_session()

      # Exactly the socket a live navigation hands to `on_mount`.
      socket = %LiveView.Socket{
        endpoint: EstoqueOSWeb.Endpoint,
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: EstoqueOS.Accounts.Scope.for_user(user)
        }
      }

      assert {:cont, _socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)

      :ok = Accounts.delete_user_session_token(token)

      {:halt, halted} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)

      assert halted.assigns.current_scope == nil
      assert {:redirect, %{to: "/users/log-in"}} = halted.redirected
    end

    test "cannot be navigated on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stock")

      :ok = conn |> Plug.Conn.get_session(:user_token) |> Accounts.delete_user_session_token()

      # The menu is still on screen, and following it must end at the login page.
      # Use a link inside the same `live_session` so the socket is what refuses
      # it; a cross-session link is a plain page load and proves nothing.
      clicked = view |> element(~s(nav a[href="/issues"])) |> render_click()
      assert {:error, {:live_redirect, %{to: "/issues"}}} = clicked

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = follow_redirect(clicked, conn)
    end
  end

  describe "the back button" do
    test "cannot be answered from the browser cache", %{conn: conn} do
      conn = get(conn, ~p"/stock")

      # `no-store` makes going back a real request, so the auth plug can refuse.
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [
               "no-store, no-cache, must-revalidate, private"
             ]
    end

    test "is refused on every page, signed in or not", %{conn: conn} do
      for path <- [~p"/", ~p"/stock", ~p"/users/log-in"] do
        conn = get(build_conn(), path)

        assert ["no-store" <> _] = Plug.Conn.get_resp_header(conn, "cache-control"),
               "#{path} may be restored from the browser cache"
      end

      conn = get(conn, ~p"/boxes")
      assert ["no-store" <> _] = Plug.Conn.get_resp_header(conn, "cache-control")
    end
  end
end
