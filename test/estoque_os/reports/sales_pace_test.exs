defmodule EstoqueOS.Reports.SalesPaceTest do
  @moduledoc """
  What the sold stock is doing.

  The marketing question is not "will the mission be short" but "what do I have
  made next", and that is three readings of the same sales: what leaves most,
  what runs out first, what is not leaving at all.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Reports

  @from Date.add(Date.utc_today(), -90)
  @to Date.utc_today()

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    small = marketing_product("Camiseta Operação Sorriso P")
    medium = marketing_product("Camiseta Operação Sorriso M")
    mug = marketing_product("Caneca Operação Sorriso")
    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})

    %{
      warehouse: warehouse,
      small: small,
      medium: medium,
      mug: mug,
      gauze: gauze
    }
  end

  defp marketing_product(name) do
    product_fixture(%{name: name, segment: "marketing"})
  end

  defp receive_stock(product, location, quantity) do
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
            unit_cost: Decimal.new("10.00")
          }
        ]
      })

    lot
  end

  # A sale is a `manual_out` to the `sale` destination — the same ledger as
  # everything else, which is the whole point of reading pace from it.
  defp sell(lot, location, quantity, days_ago) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "manual_out",
        destination: "sale",
        user_id: actor_id(),
        occurred_at: DateTime.add(DateTime.utc_now(), -days_ago * 24 * 3600, :second),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            quantity: Decimal.new(-quantity),
            sale_unit_price: Decimal.new("35.00")
          }
        ]
      })
  end

  test "the best sellers are counted in units, not in money", %{
    warehouse: warehouse,
    small: small,
    medium: medium
  } do
    small_lot = receive_stock(small, warehouse, 100)
    medium_lot = receive_stock(medium, warehouse, 100)

    sell(small_lot, warehouse, 5, 10)
    sell(medium_lot, warehouse, 30, 10)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    assert [first, second] = pace.best_sellers
    assert first.product == "Camiseta Operação Sorriso M"
    assert Decimal.equal?(first.quantity, 30)
    assert second.product == "Camiseta Operação Sorriso P"
  end

  test "cover says how many days the shelf lasts at that pace", %{
    warehouse: warehouse,
    medium: medium
  } do
    lot = receive_stock(medium, warehouse, 100)
    # 90 units over 90 days is one a day, and 10 left on the shelf.
    sell(lot, warehouse, 90, 10)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    assert [row] = pace.cover
    assert row.product == "Camiseta Operação Sorriso M"
    assert Decimal.equal?(row.quantity, 10)
    assert row.days == 10
  end

  # Half a day is not a day: a shelf that lasts eleven and a half lasts eleven,
  # and rounding up is the direction that runs out on somebody.
  test "cover rounds down", %{warehouse: warehouse, medium: medium} do
    lot = receive_stock(medium, warehouse, 100)
    sell(lot, warehouse, 90, 10)
    sell(lot, warehouse, 5, 5)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    assert [row] = pace.cover
    # 95 sold in 90 days, 5 left: 4.7 days, which is four.
    assert row.days == 4
  end

  test "idle is what is on the shelf and did not sell one unit", %{
    warehouse: warehouse,
    medium: medium,
    mug: mug
  } do
    lot = receive_stock(medium, warehouse, 100)
    receive_stock(mug, warehouse, 24)
    sell(lot, warehouse, 10, 10)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    assert [row] = pace.idle
    assert row.product == "Caneca Operação Sorriso"
    assert Decimal.equal?(row.quantity, 24)
  end

  # Something that was sold out entirely is not sitting idle — it is not
  # sitting at all, and the panel is about the shelf.
  test "an empty shelf is neither covered nor idle", %{
    warehouse: warehouse,
    medium: medium
  } do
    lot = receive_stock(medium, warehouse, 10)
    sell(lot, warehouse, 10, 10)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    assert pace.cover == []
    assert pace.idle == []
    assert [_sold] = pace.best_sellers
  end

  test "the other stock is not read at all", %{
    warehouse: warehouse,
    gauze: gauze,
    medium: medium
  } do
    receive_stock(gauze, warehouse, 400)
    lot = receive_stock(medium, warehouse, 100)
    sell(lot, warehouse, 10, 10)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    refute Enum.any?(pace.idle, &(&1.product == "Compressa de gaze 7,5x7,5"))
    assert Enum.all?(pace.best_sellers, &String.starts_with?(&1.product, "Camiseta"))
  end

  test "the totals of the period come with it", %{warehouse: warehouse, medium: medium} do
    lot = receive_stock(medium, warehouse, 100)
    sell(lot, warehouse, 4, 10)

    pace = Reports.sales_pace(@from, @to, segment: "marketing")

    assert Decimal.equal?(pace.totals.quantity, 4)
    assert Decimal.equal?(pace.totals.revenue, Decimal.new("140.00"))
    assert pace.days == 90
  end
end
