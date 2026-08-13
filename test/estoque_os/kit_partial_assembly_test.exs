defmodule EstoqueOS.KitPartialAssemblyTest do
  @moduledoc """
  Supply turns up in instalments. A kit of two components with only enough of
  one of them bought is worth building now, for as many whole kits as the
  stock on hand covers — the shelf gets tidy, and the rest is what a delivery
  still owes.

  A kit is never partially built: there is no such thing as three quarters of
  a kit lot, so what changes with the delivery is how many whole kits come
  out, never how complete one of them is.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "PK01", location_id: warehouse.id})

    gown = product_fixture(%{name: "Avental EG"})
    cannula = product_fixture(%{name: "Cânula de Guedel"})

    {:ok, kit} =
      Kits.create_kit(%{
        name: "Kit Paciente",
        items: [
          %{description: "Avental EG", quantity: Decimal.new(2), product_id: gown.id},
          %{description: "Cânula de Guedel", quantity: Decimal.new(1), product_id: cannula.id}
        ]
      })

    stock = fn product, quantity ->
      lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-01-31]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(quantity)
            }
          ]
        })
    end

    # Enough gowns for 5 kits; only 1 cannula, enough for 1.
    stock.(gown, 10)
    stock.(cannula, 1)

    %{warehouse: warehouse, box: box, kit: Kits.get_kit!(kit.id), cannula: cannula, stock: stock}
  end

  defp build(context, quantity, opts) do
    Kits.assemble(
      context.kit,
      quantity,
      Map.merge(
        %{location_id: context.warehouse.id, box_id: context.box.id, user_id: actor_id()},
        Map.new(opts)
      )
    )
  end

  test "still refuses by default", context do
    assert {:error, {:insufficient_stock, %{item: item}}} = build(context, 2, [])
    assert item.description == "Cânula de Guedel"
  end

  test "builds what the stock covers and names what stopped the rest", context do
    assert {:ok, %{quantity: built, requested: requested, bottleneck: item}} =
             build(context, 2, allow_partial: true)

    assert Decimal.equal?(built, Decimal.new(1))
    assert Decimal.equal?(requested, Decimal.new(2))
    assert item.description == "Cânula de Guedel"
  end

  test "the components that went into the whole kit really left stock", context do
    {:ok, _} = build(context, 2, allow_partial: true)

    # 1 kit built: 2 gowns and 1 cannula gone; the box holds 1 kit now, and
    # the 8 gowns nobody drew from are still sitting there, untouched.
    assert Decimal.equal?(
             Inventory.balance(box_id: context.box.id, product_id: context.kit.product.id),
             Decimal.new(1)
           )

    assert Decimal.equal?(Inventory.balance(box_id: context.box.id), Decimal.new(9))
  end

  test "a fully covered request needs no partial language", context do
    context.stock.(context.cannula, 10)

    assert {:ok, %{quantity: quantity} = result} = build(context, 2, allow_partial: true)

    assert Decimal.equal?(quantity, Decimal.new(2))
    refute Map.has_key?(result, :bottleneck)
  end

  test "refuses when nothing at all is available", context do
    empty = location_fixture(%{name: "Vazio", kind: "warehouse"})
    other_box = box_fixture(%{code: "PK99", location_id: empty.id})

    # A box with nothing in it is not a kit that is waiting — it is an empty
    # box with a label on it.
    assert {:error, :nothing_available} =
             Kits.assemble(context.kit, 1, %{
               location_id: empty.id,
               box_id: other_box.id,
               user_id: actor_id(),
               allow_partial: true
             })
  end
end
