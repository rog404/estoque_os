defmodule EstoqueOSWeb.NavigationTest do
  @moduledoc """
  The app shell. Ten flat links did not survive a phone screen, so navigation
  is grouped the way the operation is sequenced.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "groups the destinations instead of listing ten links", %{conn: conn} do
    # As the admin, who may reach all of them; other roles are in `nav_roles_test.exs`.
    %{conn: conn} = register_and_log_in_admin(%{conn: conn})
    {:ok, _view, html} = live(conn, ~p"/")

    for group <- ["Entradas", "Operação", "Estoque", "Relatórios"] do
      assert html =~ group
    end

    for path <- ~w(/invoices /stock /boxes /locations /kits
                   /load-out /issue /returns /reports/audit /issues) do
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

    # The menu names where you can be; importing is done from inside invoices.
    refute home =~ "/invoices/import"

    {:ok, _view, invoices} = live(conn, ~p"/invoices")
    assert invoices =~ "href=\"/invoices/import\""
  end

  test "appearance sits with the account, not in the bar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Aparência"
    assert html =~ "phx:set-theme"
  end

  # A `navigate` across a `live_session` reloads the page anyway, after a wasted
  # round trip, so such links must be plain hrefs.
  describe "links that cross a live_session" do
    setup %{conn: conn}, do: register_and_log_in_admin(%{conn: conn})

    test "are plain hrefs, and links inside one stay live", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # `/` and `/stock` are both `:signed_in`; `/issue` is `:money` and
      # `/conferences` is `:operational`.
      assert nav_link(html, "/stock") =~ ~s(data-phx-link="redirect")

      refute nav_link(html, "/issue") =~ "data-phx-link"
      refute nav_link(html, "/conferences") =~ "data-phx-link"
    end

    test "the brand link too, since it is on every page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/issue")
      refute nav_link(html, "/") =~ "data-phx-link"

      # `/stock` is `:signed_in` like `/`, so this one stays live.
      {:ok, _view, html} = live(conn, ~p"/stock")
      assert nav_link(html, "/") =~ ~s(data-phx-link="redirect")
    end
  end

  # The first anchor for a path; the bar and the phone menu both render and agree.
  defp nav_link(html, path) do
    case Regex.run(~r{<a[^>]*href="#{Regex.escape(path)}"[^>]*>}, html) do
      [anchor] -> anchor
      nil -> flunk("no link to #{path}")
    end
  end

  test "signed-out visitors see only the way in", %{conn: _conn} do
    conn = get(build_conn(), ~p"/users/log-in")
    html = html_response(conn, 200)

    # "Operação" alone matches the brand name.
    refute html =~ "Entradas"
    refute html =~ "Contagem de caixas"
    refute html =~ "/invoices"
  end
end
