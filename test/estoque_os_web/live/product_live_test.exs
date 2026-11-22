defmodule EstoqueOSWeb.ProductLiveTest do
  @moduledoc """
  The screen a recall needs: which lot went where, and when. It also shows the
  unit price as a series, since an average hides a price that doubled.
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

    # R$ 1,23 would destroy the unit price.
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

  # The minimum is a planning decision, not a measurement; the dashboard alarms from it.
  describe "the minimum a mission carries" do
    test "a manager sets it, and the change carries their name", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      html =
        view |> element("#minimum-form") |> render_submit(%{"min_stock_override" => "60"})

      assert html =~ "Mínimo salvo"
      assert Decimal.equal?(Repo.reload!(gauze).min_stock_override, Decimal.new(60))

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

      assert Repo.reload!(gauze).min_stock_override == nil
    end

    test "the logistics operator sees it and cannot change it", %{gauze: gauze} do
      conn =
        build_conn() |> log_in_user(EstoqueOS.AccountsFixtures.user_fixture(%{role: "logistics"}))

      {:ok, view, html} = live(conn, ~p"/products/#{gauze.id}")

      field =
        Regex.run(~r{<input[^>]*name="min_stock_override"[^>]*>}, html) |> hd()

      assert field =~ "disabled"
      assert field =~ "Somente o gestor"

      # The event is refused if it arrives anyway.
      assert render_hook(view, "set_minimum", %{"min_stock_override" => "5"}) =~ "permissão"
      assert Repo.reload!(gauze).min_stock_override == nil
    end
  end

  test "the stock screen links to it", %{conn: conn, gauze: gauze} do
    {:ok, _view, html} = live(conn, ~p"/stock")

    assert html =~ ~s(href="/products/#{gauze.id}")
  end

  describe "writing it off from here" do
    test "the button carries the product to the write-off screen", %{conn: conn, gauze: gauze} do
      {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

      assert html =~ ~s(href="/issue?product=#{gauze.id}")
    end

    test "arriving there opens the product already picked", %{conn: conn, gauze: gauze} do
      {:ok, view, html} = live(conn, ~p"/issue?product=#{gauze.id}")

      # The quantity form, not the search field: the product is already chosen.
      assert has_element?(view, "#issue-form")
      assert html =~ "Gaze estéril"
    end

    test "an id that resolves to nothing still opens the screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue?product=999999")

      refute has_element?(view, "#issue-form")
    end

    # The route is the manager's; a shortcut the router refuses is a dead door.
    test "the logistics operator is not offered it", %{gauze: gauze} do
      %{conn: conn} = register_and_log_in_logistics(%{conn: build_conn()})

      {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

      refute html =~ ~s(href="/issue?product=#{gauze.id}")
    end
  end

  describe "putting loose stock away" do
    setup %{warehouse: warehouse, gauze: gauze} do
      loose = lot_fixture(%{product_id: gauze.id, lot_number: "L-SOLTO"})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{lot_id: loose.id, location_id: warehouse.id, quantity: Decimal.new(60)}
          ]
        })

      %{loose: loose}
    end

    test "a loose lot goes into a box from the product's own page", %{
      conn: conn,
      gauze: gauze,
      loose: loose,
      box: box,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      html =
        view
        |> element("#stow-#{loose.id}-#{warehouse.id}")
        |> render_submit(%{"box_code" => "PL01", "quantity" => "60"})

      assert html =~ "Guardado em PL01"

      assert Decimal.equal?(
               Inventory.balance(lot_id: loose.id, box_id: box.id),
               Decimal.new(60)
             )

      assert Decimal.equal?(
               Inventory.balance(lot_id: loose.id, location_id: warehouse.id, box_id: nil),
               Decimal.new(0)
             )
    end

    test "an unknown code is a typo, not a new box", %{
      conn: conn,
      gauze: gauze,
      loose: loose,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      html =
        view
        |> element("#stow-#{loose.id}-#{warehouse.id}")
        |> render_submit(%{"box_code" => "ZZ99", "quantity" => "60"})

      assert html =~ "ZZ99"
      refute EstoqueOS.Repo.get_by(EstoqueOS.Inventory.Box, code: "ZZ99")

      assert Decimal.equal?(
               Inventory.balance(lot_id: loose.id, location_id: warehouse.id, box_id: nil),
               Decimal.new(60)
             )
    end

    test "a line already in a box is offered no form", %{
      conn: conn,
      gauze: gauze,
      lot: lot,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      refute has_element?(view, "#stow-#{lot.id}-#{warehouse.id}")
    end

    # Marketing writes to the ledger but has no boxes; this page is shared with it.
    test "marketing is offered no box at all", %{gauze: gauze, loose: loose, warehouse: warehouse} do
      {:ok, marketing} = Catalog.update_product(gauze, %{segment: "marketing"})
      %{conn: conn} = register_and_log_in_as(%{conn: build_conn()}, "marketing")

      {:ok, view, _html} = live(conn, ~p"/products/#{marketing.id}")

      refute has_element?(view, "#stow-#{loose.id}-#{warehouse.id}")
    end
  end

  describe "taking a product out of the catalog" do
    # Rendered and disabled, never absent: a hidden control reads as a missing feature.
    test "is refused while the product is on a shelf, and the reason says why", %{
      conn: conn,
      gauze: gauze
    } do
      {:ok, view, html} = live(conn, ~p"/products/#{gauze.id}")

      assert has_element?(view, "button[data-confirm-open='deactivate-product'][disabled]")

      # The reason lives in `title`, an attribute: stripping tags would hide it.
      assert html =~ "1 posição(ões) em estoque"
      refute has_element?(view, "#deactivate-product-form")
    end

    test "goes through once the stock is gone", %{
      conn: conn,
      gauze: gauze,
      lot: lot,
      warehouse: warehouse,
      box: box
    } do
      empty_out(lot, warehouse, box)

      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      refute has_element?(view, "button[data-confirm-open='deactivate-product'][disabled]")

      html = view |> form("#deactivate-product-form") |> render_submit()

      refute Repo.reload(gauze).active
      assert text_of(html) =~ "saiu do catálogo"
      assert text_of(html) =~ "desativado"
    end

    test "and comes back from the same screen", %{
      conn: conn,
      gauze: gauze,
      lot: lot,
      warehouse: warehouse,
      box: box
    } do
      empty_out(lot, warehouse, box)
      {:ok, _} = Catalog.deactivate_product(gauze)

      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      html = view |> element("button[phx-click='reactivate']") |> render_click()

      assert Repo.reload(gauze).active
      assert text_of(html) =~ "voltou para o catálogo"
    end

    test "the logistics operator is not offered it", %{gauze: gauze} do
      %{conn: conn} = register_and_log_in_logistics(%{conn: build_conn()})

      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      refute has_element?(view, "button[data-confirm-open='deactivate-product']")
    end

    # Absent markup is not a rule: a hand-crafted event arrives all the same.
    test "and cannot send the event either", %{
      gauze: gauze,
      lot: lot,
      warehouse: warehouse,
      box: box
    } do
      empty_out(lot, warehouse, box)
      %{conn: conn} = register_and_log_in_logistics(%{conn: build_conn()})

      {:ok, view, _html} = live(conn, ~p"/products/#{gauze.id}")

      render_hook(view, "deactivate", %{})

      assert Repo.reload(gauze).active
    end

    test "the change log says what it was, not always the minimum", %{
      conn: conn,
      gauze: gauze,
      lot: lot,
      warehouse: warehouse,
      box: box
    } do
      empty_out(lot, warehouse, box)
      {:ok, _} = Catalog.deactivate_product(gauze)

      {:ok, _view, html} = live(conn, ~p"/products/#{gauze.id}")

      stripped = text_of(html)
      assert stripped =~ "saiu do catálogo"
      refute stripped =~ "mínimo true"
    end
  end

  # Strip tags first: "300" lives inside `border-base-300`.
  defp text_of(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  defp empty_out(lot, warehouse, box) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "manual_out",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: box.id,
            quantity: Decimal.new(-100)
          }
        ]
      })
  end
end
