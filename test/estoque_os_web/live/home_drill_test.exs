defmodule EstoqueOSWeb.HomeDrillTest do
  @moduledoc """
  The overview shows a preview and hands off: the link appears only when the
  list is capped, and lands on the narrowed view.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup :register_and_log_in_operator

  defp stock_expiring_in(days, quantity) do
    location = location_fixture()
    lot = lot_fixture(%{expires_on: Date.add(Date.utc_today(), days)})

    {:ok, _tx} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [%{lot_id: lot.id, location_id: location.id, quantity: quantity}]
      })

    lot
  end

  test "offers no way deeper when there is nothing deeper", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "See all expiring stock"
    refute html =~ "Ver todo o estoque vencendo"
  end

  test "offers the link once the preview is capped, and it lands filtered", %{conn: conn} do
    lots = for _ <- 1..6, do: stock_expiring_in(10, 5)

    {:ok, view, html} = live(conn, ~p"/")

    shown = Enum.count(lots, &String.contains?(html, &1.lot_number))
    assert shown == 5, "expected 5 of 6 expiring lots previewed, got #{shown}"

    assert html =~ "Ver todo o estoque vencendo"

    {:ok, _stock, stock_html} =
      view
      |> element("a", "Ver todo o estoque vencendo")
      |> render_click()
      |> follow_redirect(conn)

    # The situation filter is a row of chips; the matching one arrives ticked.
    assert stock_html =~ ~r/name="situation\[\]"[^>]*value="expiring"[^>]*checked/
  end

  # Shortages have nowhere deeper to go, so this card lists in full with no
  # handoff; a future shortages screen should make this test fail.
  test "shortages are listed in full on the overview, with no handoff", %{conn: conn} do
    # `below_minimum/1` only considers products that have moved at least once,
    # or the seeded catalog's untouched lines would bury the ones that ran low.
    products =
      for _ <- 1..7 do
        product = product_fixture(%{min_stock_override: Decimal.new(100)})
        lot = lot_fixture(%{product_id: product.id})
        location = location_fixture()

        {:ok, _tx} =
          Inventory.post_transaction(%{
            type: "purchase_in",
            user_id: actor_id(),
            entries: [%{lot_id: lot.id, location_id: location.id, quantity: 5}]
          })

        product
      end

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Abaixo do mínimo da missão"

    shown = Enum.count(products, &String.contains?(html, &1.name))

    assert shown == 7,
           "the shortage card is not a preview; expected all 7 listed, got #{shown}"

    refute html =~ "below-minimum"
  end
end
