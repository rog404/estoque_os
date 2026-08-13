defmodule EstoqueOS.Inventory.AverageCostTest do
  @moduledoc """
  The same gauze arrives on three invoices at three prices. What is it worth?

  Decided 2026-08-10: a weighted moving average over the stock on hand. The two
  things that make it honest are pinned here, because both are the kind of rule
  that a later refactor quietly breaks and no screen would show.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal"})
    product = product_fixture(%{name: "Compressa de gaze"})
    %{warehouse: warehouse, product: product}
  end

  defp bring_in(product, location, quantity, unit_cost) do
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
            unit_cost: unit_cost && Decimal.new(unit_cost)
          }
        ]
      })

    lot
  end

  test "weights each lot by how much of it is still here", %{
    product: product,
    warehouse: warehouse
  } do
    bring_in(product, warehouse, 100, "1.00")
    bring_in(product, warehouse, 300, "2.00")

    # (100×1 + 300×2) / 400 = 1.75 — not the 1.50 a plain mean would give.
    assert %{average: average, quantity: quantity} =
             Inventory.average_cost_by_product()[product.id]

    assert Decimal.equal?(Decimal.round(average, 2), Decimal.new("1.75"))
    assert Decimal.equal?(quantity, Decimal.new(400))
  end

  # SPEC §4.7: a donation has no cost, and zero is not the same as unknown.
  test "leaves donated stock out of the average instead of counting it as zero", %{
    product: product,
    warehouse: warehouse
  } do
    bring_in(product, warehouse, 100, "2.00")
    bring_in(product, warehouse, 300, nil)

    assert %{average: average, priced_quantity: priced, unpriced_quantity: unpriced} =
             Inventory.average_cost_by_product()[product.id]

    # Counted as zero the average would be 0.50, which understates every value
    # built on it.
    assert Decimal.equal?(Decimal.round(average, 2), Decimal.new("2.00"))
    assert Decimal.equal?(priced, Decimal.new(100))
    assert Decimal.equal?(unpriced, Decimal.new(300))
  end

  test "says it does not know, rather than saying zero", %{
    product: product,
    warehouse: warehouse
  } do
    bring_in(product, warehouse, 50, nil)

    assert %{average: nil, unpriced_quantity: unpriced, known_value: value} =
             Inventory.average_cost_by_product()[product.id]

    assert Decimal.equal?(unpriced, Decimal.new(50))
    assert Decimal.equal?(value, Decimal.new(0))
  end

  # Stock that has left is not stock: the average follows what is on the shelf.
  test "moves as stock leaves", %{product: product, warehouse: warehouse} do
    cheap = bring_in(product, warehouse, 100, "1.00")
    bring_in(product, warehouse, 100, "3.00")

    assert %{average: before} = Inventory.average_cost_by_product()[product.id]
    assert Decimal.equal?(Decimal.round(before, 2), Decimal.new("2.00"))

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "manual_out",
        user_id: actor_id(),
        entries: [
          %{lot_id: cheap.id, location_id: warehouse.id, quantity: Decimal.new(-100)}
        ]
      })

    assert %{average: after_issue} = Inventory.average_cost_by_product()[product.id]
    assert Decimal.equal?(Decimal.round(after_issue, 2), Decimal.new("3.00"))
  end

  # The entries keep the price they entered at. That is the auditor's trail, and
  # the average is only ever derived from it.
  test "never writes back into the ledger", %{product: product, warehouse: warehouse} do
    lot = bring_in(product, warehouse, 100, "1.00")
    bring_in(product, warehouse, 300, "2.00")

    Inventory.average_cost_by_product()

    entry =
      EstoqueOS.Inventory.TransactionEntry
      |> EstoqueOS.Repo.get_by!(lot_id: lot.id)

    assert Decimal.equal?(entry.unit_cost, Decimal.new("1.00"))
  end

  test "can be asked about specific products only", %{product: product, warehouse: warehouse} do
    other = product_fixture(%{name: "Avental"})
    bring_in(product, warehouse, 10, "1.00")
    bring_in(other, warehouse, 10, "5.00")

    costs = Inventory.average_cost_by_product([product.id])

    assert Map.has_key?(costs, product.id)
    refute Map.has_key?(costs, other.id)
  end
end
