defmodule EstoqueOS.ManualIssueBoxTest do
  @moduledoc """
  FEFO picks across the whole location by default — the same behaviour as
  always. A line naming a `box_id` narrows that to just the one box, which is
  how the write-off screen lets an operator override the recommendation
  instead of always trusting it.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    product = product_fixture()

    near = box_fixture(%{code: "N01", location_id: warehouse.id})
    far = box_fixture(%{code: "F02", location_id: warehouse.id})

    near_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-09-30]})
    far_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-06-30]})

    stock_in(near_lot, warehouse, 10, box_id: near.id)
    stock_in(far_lot, warehouse, 10, box_id: far.id)

    %{
      warehouse: warehouse,
      product: product,
      near: near,
      far: far,
      near_lot: near_lot,
      far_lot: far_lot
    }
  end

  defp stock_in(lot, location, quantity, opts) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity)
          }
        ]
      })
  end

  test "without a box_id, FEFO reaches across every box", %{
    product: product,
    warehouse: warehouse,
    near_lot: near_lot,
    far_lot: far_lot
  } do
    assert {:ok, _} =
             Outbound.issue_many([%{product_id: product.id, quantity: Decimal.new(15)}], %{
               location_id: warehouse.id,
               user_id: actor_id()
             })

    # 10 from the box expiring soonest, then 5 more from the other.
    assert Decimal.equal?(Inventory.balance(lot_id: near_lot.id), Decimal.new(0))
    assert Decimal.equal?(Inventory.balance(lot_id: far_lot.id), Decimal.new(5))
  end

  test "a box_id restricts the pick to that box alone", %{
    product: product,
    warehouse: warehouse,
    near: near,
    far: far,
    near_lot: near_lot,
    far_lot: far_lot
  } do
    assert {:ok, _} =
             Outbound.issue_many(
               [%{product_id: product.id, quantity: Decimal.new(4), box_id: far.id}],
               %{location_id: warehouse.id, user_id: actor_id()}
             )

    assert Decimal.equal?(Inventory.balance(lot_id: far_lot.id), Decimal.new(6))
    assert Decimal.equal?(Inventory.balance(lot_id: near_lot.id), Decimal.new(10))
    assert Decimal.equal?(Inventory.balance(box_id: near.id), Decimal.new(10))
  end

  test "refuses a box_id that cannot cover the quantity, even though another box could", %{
    product: product,
    warehouse: warehouse,
    near: near
  } do
    assert {:error, {:insufficient_stock, %{missing: missing}}} =
             Outbound.issue_many(
               [%{product_id: product.id, quantity: Decimal.new(20), box_id: near.id}],
               %{location_id: warehouse.id, user_id: actor_id()}
             )

    assert Decimal.equal?(missing, Decimal.new(10))

    # Nothing was posted while it was refused.
    assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(20))
  end
end
