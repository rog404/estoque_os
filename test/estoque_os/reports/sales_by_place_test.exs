defmodule EstoqueOS.Reports.SalesByPlaceTest do
  @moduledoc """
  What was sold, grouped by where it went out from.

  For the marketing stock the place *is* the event: a mission site, a fair, the
  office counter. "Quanto vendemos em Manacapuru" was a question the ledger
  could already answer and no screen asked.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Reports}

  @from Date.add(Date.utc_today(), -90)
  @to Date.utc_today()

  setup do
    office = location_fixture(%{name: "Escritório São Paulo", kind: "other"})
    mission = location_fixture(%{name: "Missão Manacapuru", kind: "mission_site"})
    shirt = product_fixture(%{name: "Camiseta Operação Sorriso G", segment: "marketing"})
    gauze = product_fixture(%{name: "Compressa de gaze"})

    %{office: office, mission: mission, shirt: shirt, gauze: gauze}
  end

  defp stock_in(product, location, quantity, cost) do
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            quantity: Decimal.new(quantity),
            unit_cost: cost && Decimal.new(cost)
          }
        ]
      })

    lot
  end

  defp sell(lot, location, quantity, price) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "manual_out",
        destination: "sale",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            quantity: Decimal.new(-quantity),
            sale_unit_price: Decimal.new(price)
          }
        ]
      })
  end

  test "separates the mission from the office", %{
    office: office,
    mission: mission,
    shirt: shirt
  } do
    at_office = stock_in(shirt, office, 100, "18.00")
    at_mission = stock_in(shirt, mission, 100, "18.00")

    sell(at_office, office, 4, "40.00")
    sell(at_mission, mission, 10, "40.00")

    [first, second] = Reports.sales_by_place(@from, @to, segment: "marketing")

    # Sorted by revenue, so the mission comes first.
    assert first.location == "Missão Manacapuru"
    assert first.kind == "mission_site"
    assert Decimal.equal?(first.quantity, 10)
    assert Decimal.equal?(first.revenue, Decimal.new("400.00"))
    assert Decimal.equal?(first.cost, Decimal.new("180.00"))
    assert Decimal.equal?(first.margin, Decimal.new("220.00"))

    assert second.location == "Escritório São Paulo"
    assert Decimal.equal?(second.revenue, Decimal.new("160.00"))
  end

  # A donated lot has no cost, and counting it as zero would report the whole
  # sale as margin.
  test "says how many lines carry no cost", %{office: office, shirt: shirt} do
    lot = stock_in(shirt, office, 50, nil)
    sell(lot, office, 5, "40.00")

    [place] = Reports.sales_by_place(@from, @to, segment: "marketing")

    assert place.unpriced == 1
    assert Decimal.equal?(place.cost, Decimal.new(0))
  end

  test "reads only the stock it was asked about", %{office: office, shirt: shirt, gauze: gauze} do
    shirts = stock_in(shirt, office, 50, "18.00")
    gauzes = stock_in(gauze, office, 50, "1.20")

    sell(shirts, office, 5, "40.00")
    sell(gauzes, office, 5, "3.00")

    [marketing] = Reports.sales_by_place(@from, @to, segment: "marketing")
    assert Decimal.equal?(marketing.quantity, 5)

    [both] = Reports.sales_by_place(@from, @to)
    assert Decimal.equal?(both.quantity, 10)
  end

  # A write-off that went anywhere else is not a sale, whatever it looked like.
  test "counts sales and nothing else", %{office: office, shirt: shirt} do
    lot = stock_in(shirt, office, 50, "18.00")

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "manual_out",
        destination: "donation",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: office.id, quantity: Decimal.new(-5)}
        ]
      })

    assert Reports.sales_by_place(@from, @to) == []
  end

  test "leaves out what happened outside the period", %{office: office, shirt: shirt} do
    lot = stock_in(shirt, office, 50, "18.00")
    sell(lot, office, 5, "40.00")

    long_ago = Date.add(Date.utc_today(), -365)

    assert Reports.sales_by_place(long_ago, Date.add(long_ago, 30)) == []
  end
end
