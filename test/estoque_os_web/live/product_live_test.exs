defmodule EstoqueOSWeb.ProductLiveTest do
  @moduledoc """
  The screen a recall needs: which lot of that gauze went where, and when.

  It is also where the unit price becomes visible as a series rather than an
  average. A price that doubled between two invoices is a conversation with a
  supplier, and an average hides it.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Catalog, Inventory, Missions, Outbound}
  alias EstoqueOS.Repo

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "PL01", location_id: warehouse.id})
    gauze = product_fixture(%{name: "Gaze estéril", controlled: true})
    lot = lot_fixture(%{product_id: gauze.id, lot_number: "L-7788", expires_on: ~D[2028-01-31]})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: box.id,
            quantity: Decimal.new(100),
            unit_cost: Decimal.new("1.2345")
          }
        ]
      })

    %{warehouse: warehouse, box: box, gauze: gauze, lot: lot}
  end

  test "shows where the stock is, lot and box named", %{conn: conn, gauze: gauze} do
    {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

    assert html =~ "Gaze estéril"
    assert html =~ "L-7788"
    assert html =~ "PL01"
    assert html =~ "Estoque Principal"
    assert html =~ "controlled" or html =~ "controlado"
  end

  test "shows the unit price at full precision, not rounded to money", %{
    conn: conn,
    gauze: gauze
  } do
    {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

    # R$ 1,23 would destroy the number the whole system exists to produce.
    assert html =~ "1,2345"
  end

  test "lists a departure with its sign, and names the mission", context do
    %{conn: conn, gauze: gauze, warehouse: warehouse, box: box} = context
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    {:ok, mission} =
      Missions.create_mission(%{
        name: "Tefé 2026/1",
        location_id: site.id,
        starts_on: Date.utc_today(),
        ends_on: Date.add(Date.utc_today(), 7)
      })

    {:ok, _} =
      Outbound.load_out(%{
        source_location_id: warehouse.id,
        destination_location_id: site.id,
        box_ids: [box.id],
        user_id: actor_id()
      })

    {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

    assert html =~ mission.name
    assert html =~ "Derrubada" or html =~ "Load-out"
    # The sign is how a reader tells an arrival from a departure at a glance.
    assert html =~ "-100"
    assert html =~ "+100"
  end

  test "a product that never moved says so instead of rendering empty", %{conn: conn} do
    untouched = product_fixture(%{name: "Nunca usado"})

    {:ok, _view, html} = live(conn, ~p"/products/#{untouched.id}")

    assert html =~ "nunca se movimentou"
    assert html =~ "Nada disso em estoque agora"
  end

  test "a viewer may read it", %{gauze: gauze} do
    conn = build_conn() |> log_in_user(EstoqueOS.AccountsFixtures.user_fixture())

    assert {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")
    assert html =~ "Gaze estéril"
  end

  # The minimum is the one figure on this screen that is a decision rather than
  # a measurement, and it is a planning decision: argued with the ONG team, and
  # what the dashboard raises alarms from.
  describe "the minimum a mission carries" do
    test "a manager sets it, and the change carries their name", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      html =
        view |> element("#minimum-form") |> render_submit(%{"min_stock_override" => "60"})

      assert html =~ "Mínimo salvo"
      assert Decimal.equal?(Repo.reload!(gauze).min_stock_override, Decimal.new(60))

      # "Who lowered it, and when" is the question asked after a mission runs
      # short, which is exactly when nobody remembers.
      assert [change] = Catalog.product_changes(gauze.id)
      assert change.field == "min_stock_override"
      assert change.from_value == nil
      assert change.to_value == "60"
      assert change.user_id
    end

    test "clearing it means unknown, not zero", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      view |> element("#minimum-form") |> render_submit(%{"min_stock_override" => "60"})
      view |> element("#minimum-form") |> render_submit(%{"min_stock_override" => ""})

      # Zero would mean "we are content to carry none of this".
      assert Repo.reload!(gauze).min_stock_override == nil
    end

    test "the logistics operator sees it and cannot change it", %{gauze: gauze} do
      conn =
        build_conn() |> log_in_user(EstoqueOS.AccountsFixtures.user_fixture(%{role: "logistics"}))

      {:ok, view, html} = live(conn, ~p"/products/#{gauze.id}")

      # Shown and disabled, with the reason — never simply gone.
      field =
        Regex.run(~r{<input[^>]*name="min_stock_override"[^>]*>}, html) |> hd()

      assert field =~ "disabled"
      assert field =~ "Somente o gestor"

      # And the event is refused if it arrives anyway.
      assert render_hook(view, "set_minimum", %{"min_stock_override" => "5"}) =~ "permissão"
      assert Repo.reload!(gauze).min_stock_override == nil
    end
  end

  test "the stock screen links to it", %{conn: conn, gauze: gauze} do
    {:ok, _view, html} = live(conn, ~p"/stock")

    assert html =~ ~s(href="/products/#{gauze.id}")
  end

  # The screen that answers "how much of this is left" is the screen somebody is
  # standing on when they decide to take some out. Sending them to the menu and
  # then to a search field, to type the name of the product whose page they were
  # already reading, is three steps to arrive where they started.
  describe "writing it off from here" do
    test "the button carries the product to the write-off screen", %{conn: conn, gauze: gauze} do
      {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

      assert html =~ ~s(href="/issue?product=#{gauze.id}")
    end

    test "arriving there opens the product already picked", %{conn: conn, gauze: gauze} do
      {:ok, view, html} = live(conn, ~p"/issue?product=#{gauze.id}")

      # The quantity form, not the search field: the product is chosen and the
      # only thing left to say is how many.
      assert has_element?(view, "#issue-form")
      assert html =~ "Gaze estéril"
    end

    # A product deactivated between the two pages is a link that no longer leads
    # anywhere, not a crash.
    test "an id that resolves to nothing still opens the screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue?product=999999")

      refute has_element?(view, "#issue-form")
    end

    # The route is the manager's. A shortcut the router would refuse is the same
    # dead door as the menu entry that was taken away.
    test "the logistics operator is not offered it", %{gauze: gauze} do
      %{conn: conn} = register_and_log_in_logistics(%{conn: build_conn()})

      {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

      refute html =~ ~s(href="/issue?product=#{gauze.id}")
    end
  end
end
