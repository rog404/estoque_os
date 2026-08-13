defmodule EstoqueOSWeb.NavigationTest do
  @moduledoc """
  The app shell. Ten flat links did not survive a phone screen, so navigation
  is grouped the way the operation is sequenced.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "groups the destinations instead of listing ten links", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    for group <- ["Entradas", "Operação", "Estoque", "Relatórios"] do
      assert html =~ group
    end

    # Every destination is still reachable, one level down.
    for path <- ~w(/invoices /stock /boxes /locations /kits
                   /load-out /issue /returns /audit /reports/audit /issues) do
      assert html =~ "href=\"#{path}\""
    end
  end

  test "marks where you are", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/boxes")

    assert html =~ "menu-active"
  end

  test "keeps the account actions out of the way but reachable", %{conn: conn, user: user} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ user.email
    assert html =~ "/users/settings"
    assert html =~ "/users/log-out"
  end

  test "importing is a step inside invoices, not a destination in the menu", %{conn: conn} do
    {:ok, _view, home} = live(conn, ~p"/")

    # It once sat in three places at once: the bar as a primary button, the
    # dashboard header, and the Entradas group. The menu names where you can
    # *be*; importing is something you do once you are already in invoices, and
    # that screen offers it twice — in its header and in its empty state.
    refute home =~ "/invoices/import"

    {:ok, _view, invoices} = live(conn, ~p"/invoices")
    assert invoices =~ "href=\"/invoices/import\""
  end

  test "appearance sits with the account, not in the bar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Aparência"
    assert html =~ "phx:set-theme"
  end

  test "signed-out visitors see only the way in", %{conn: _conn} do
    conn = get(build_conn(), ~p"/users/log-in")
    html = html_response(conn, 200)

    # "Operação" alone would match the brand name; check a menu destination.
    refute html =~ "Entradas"
    refute html =~ "Contagem de caixas"
    refute html =~ "/invoices"
  end
end
