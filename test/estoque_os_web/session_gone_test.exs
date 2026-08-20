defmodule EstoqueOSWeb.SessionGoneTest do
  @moduledoc """
  What a screen does once the session behind it is gone.

  Two ways it used to keep working, both reported by Rogerio on 2026-08-20 as
  "estou deslogado e consigo acessar outras páginas":

    1. **The tab that was already open.** A live navigation runs `mount` again
       on the same socket, and that socket already carried `current_scope` from
       the moment it connected. Read through `assign_new`, the token was
       therefore checked once — when the tab opened — and never again. Losing
       the session and clicking the menu still worked.

    2. **The back button.** A page restored from the browser's cache is never
       re-checked with the server, so going back showed the stock as it was a
       minute ago, to somebody with no session at all.

  Neither is a hole in the router. Both are a page trusting an answer that had
  expired.
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

      # Exactly the socket a live navigation hands to `on_mount`: connected,
      # and already carrying the scope from when the tab was opened.
      socket = %LiveView.Socket{
        endpoint: EstoqueOSWeb.Endpoint,
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: EstoqueOS.Accounts.Scope.for_user(user)
        }
      }

      # Still signed in: the same socket, the same session, nothing revoked.
      assert {:cont, _socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)

      # And now the session is gone — expired, or logged out from a phone.
      :ok = Accounts.delete_user_session_token(token)

      {:halt, halted} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)

      assert halted.assigns.current_scope == nil
      assert {:redirect, %{to: "/users/log-in"}} = halted.redirected
    end

    test "cannot be navigated on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stock")

      # The session goes out from under the open page: expired, or logged out
      # from another device.
      :ok = conn |> Plug.Conn.get_session(:user_token) |> Accounts.delete_user_session_token()

      # The menu is still on screen — the page it is drawn on has not been
      # repainted — and following it now has to end at the login page rather
      # than at the boxes. End to end, the way it was reported: click the menu,
      # and see what the app answers.
      clicked = view |> element(~s(nav a[href="/boxes"])) |> render_click()
      assert {:error, {:live_redirect, %{to: "/boxes"}}} = clicked

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = follow_redirect(clicked, conn)
    end
  end

  describe "the back button" do
    test "cannot be answered from the browser cache", %{conn: conn} do
      conn = get(conn, ~p"/stock")

      # `no-store` is what makes going back a real request instead of a redraw
      # of what the browser kept. Without it the auth plug never runs, so it
      # never gets the chance to refuse.
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

      # And the signed-in session says the same.
      conn = get(conn, ~p"/boxes")
      assert ["no-store" <> _] = Plug.Conn.get_resp_header(conn, "cache-control")
    end
  end
end
