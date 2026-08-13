defmodule EstoqueOS.KitLocationTest do
  @moduledoc """
  "Which box is that kit in" is answered the same way it is for any product
  now: a lot, in a box, at a location. What used to require a dedicated
  `KitAssembly` row is now `Inventory.position_balances/2` on the kit's own
  product.

  A recalled component lot is still findable — that is what
  `EstoqueOS.Kits.KitLotProvenance` is for, not the box's own contents.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    gauze = product_fixture(%{name: "Gaze"})
    opioid = product_fixture(%{name: "Fentanila", controlled: true})

    {:ok, kit} =
      Kits.create_kit(%{
        name: "Kit Anestesia",
        items: [
          %{description: "Gaze", quantity: Decimal.new(2), product_id: gauze.id},
          %{description: "Fentanila", quantity: Decimal.new(1), product_id: opioid.id}
        ]
      })

    # Different expiries on purpose: the kit's lot follows the earliest of them.
    gauze_lot = lot_fixture(%{product_id: gauze.id, expires_on: ~D[2029-12-31]})
    opioid_lot = lot_fixture(%{product_id: opioid.id, expires_on: ~D[2027-03-31]})

    stock_in(gauze_lot, warehouse, 40)
    stock_in(opioid_lot, warehouse, 20)

    %{warehouse: warehouse, kit: Kits.get_kit!(kit.id), opioid_lot: opioid_lot}
  end

  defp stock_in(lot, location, quantity, opts \\ []) do
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

  test "says which box holds the kit, and how many", %{kit: kit, warehouse: warehouse} do
    box = box_fixture(%{code: "AN07", location_id: warehouse.id})

    {:ok, %{lot: lot}} =
      Kits.assemble(kit, 3, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

    assert [%{box_id: found_box_id, quantity: quantity}] =
             Inventory.position_balances(kit.product.id, location_id: warehouse.id)

    assert found_box_id == box.id
    assert Decimal.equal?(quantity, Decimal.new(3))
    assert lot.expires_on == ~D[2027-03-31]
  end

  test "a kit carrying a controlled component is itself controlled", %{
    kit: kit,
    warehouse: warehouse
  } do
    box = box_fixture(%{code: "AN09", location_id: warehouse.id})

    {:ok, _} =
      Kits.assemble(kit, 1, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

    assert Kits.get_kit!(kit.id).product.controlled
  end

  test "removing the controlled component lifts the flag", %{kit: kit} do
    [opioid_item] = Enum.filter(kit.items, &(&1.description == "Fentanila"))

    {:ok, _} = Kits.remove_kit_item(opioid_item)

    refute Kits.get_kit!(kit.id).product.controlled
  end

  test "a box can hold several kits, of more than one type", %{kit: kit, warehouse: warehouse} do
    gauze = product_fixture(%{name: "Gaze extra"})
    lot = lot_fixture(%{product_id: gauze.id, expires_on: ~D[2030-01-31]})
    stock_in(lot, warehouse, 30)

    {:ok, other} =
      Kits.create_kit(%{
        name: "Kit Curativo",
        items: [%{description: "Gaze extra", quantity: Decimal.new(3), product_id: gauze.id}]
      })

    box = box_fixture(%{code: "AN10", location_id: warehouse.id})

    {:ok, _} =
      Kits.assemble(kit, 2, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

    {:ok, _} =
      Kits.assemble(Kits.get_kit!(other.id), 4, %{
        location_id: warehouse.id,
        box_id: box.id,
        user_id: actor_id()
      })

    contents = Inventory.Locations.box_contents(Inventory.Locations.get_box!(box.id))
    names = contents |> Enum.map(& &1.product) |> Enum.sort()

    assert names == ["Kit Anestesia", "Kit Curativo"]
  end

  test "a recalled component lot can be traced to the kit lot it went into", %{
    kit: kit,
    warehouse: warehouse,
    opioid_lot: opioid_lot
  } do
    box = box_fixture(%{code: "AN11", location_id: warehouse.id})

    {:ok, %{lot: kit_lot}} =
      Kits.assemble(kit, 2, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

    provenance =
      EstoqueOS.Kits.KitLotProvenance
      |> EstoqueOS.Repo.get_by(component_lot_id: opioid_lot.id, kit_lot_id: kit_lot.id)

    assert provenance
    assert Decimal.equal?(provenance.quantity, Decimal.new(2))

    # From the recalled lot, the kit lot; from the kit lot, where it is now —
    # the same query any other product's recall already uses.
    assert [%{box_id: found_box_id}] =
             Inventory.position_balances(kit.product.id, location_id: warehouse.id)

    assert found_box_id == box.id
  end
end
