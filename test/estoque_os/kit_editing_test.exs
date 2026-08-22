defmodule EstoqueOS.KitEditingTest do
  @moduledoc """
  A kit is a recipe, and recipes change: a component is discontinued, a quantity
  was wrong, the surgical team asks for one more drape.

  Editing reaches into no box. What is inside one is whatever the ledger says was
  moved there, and that is untouched. What does change is what the box's label
  means, so the screen says how many boxes carry it — a warning, not a refusal.
  A recipe that cannot be corrected is a recipe that goes stale.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    gown = product_fixture(%{name: "Avental EG"})
    drape = product_fixture(%{name: "Campo cirúrgico"})

    {:ok, kit} =
      Kits.create_kit(%{
        name: "Kit Paciente",
        items: [%{description: "Avental EG", quantity: Decimal.new(4), product_id: gown.id}]
      })

    %{warehouse: warehouse, gown: gown, drape: drape, kit: Kits.get_kit!(kit.id)}
  end

  describe "create_kit/1" do
    test "makes a kit with no components yet" do
      assert {:ok, kit} = Kits.create_kit(%{name: "Kit Recuperação"})
      assert Kits.get_kit!(kit.id).items == []
    end

    test "refuses a name the catalog already has" do
      assert {:error, changeset} = Kits.create_kit(%{name: "kit paciente"})
      assert errors_on(changeset).name
    end
  end

  describe "editing the bill of materials" do
    test "adds a component", %{kit: kit, drape: drape} do
      assert {:ok, _} =
               Kits.add_kit_item(kit, %{
                 description: "Campo cirúrgico",
                 quantity: Decimal.new(2),
                 product_id: drape.id
               })

      assert length(Kits.get_kit!(kit.id).items) == 2
    end

    test "changes a quantity", %{kit: kit} do
      [item] = kit.items

      assert {:ok, _} = Kits.update_kit_item(item, %{quantity: Decimal.new(6)})
      assert [%{quantity: quantity}] = Kits.get_kit!(kit.id).items
      assert Decimal.equal?(quantity, Decimal.new(6))
    end

    test "refuses a quantity of zero", %{kit: kit} do
      [item] = kit.items

      assert {:error, changeset} = Kits.update_kit_item(item, %{quantity: Decimal.new(0)})
      assert errors_on(changeset).quantity
    end

    test "removes a component", %{kit: kit} do
      [item] = kit.items

      assert {:ok, _} = Kits.remove_kit_item(item)
      assert Kits.get_kit!(kit.id).items == []
    end

    test "renames the kit", %{kit: kit} do
      assert {:ok, renamed} = Kits.update_kit(kit, %{name: "Kit Paciente v2"})
      assert renamed.name == "Kit Paciente v2"
    end
  end

  describe "a kit that is already packed into boxes" do
    setup %{kit: kit, warehouse: warehouse, gown: gown} do
      box = box_fixture(%{code: "KE01", location_id: warehouse.id})
      lot = lot_fixture(%{product_id: gown.id, expires_on: ~D[2028-01-31]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(40)
            }
          ]
        })

      {:ok, _} =
        Kits.assemble(kit, 2, %{location_id: warehouse.id, box_id: box.id, user_id: actor_id()})

      %{box: box}
    end

    test "says how many kits are in stock", %{kit: kit} do
      assert Decimal.equal?(Kits.assembled_count(kit), Decimal.new(2))
    end

    test "still allows the recipe to be corrected", %{kit: kit, drape: drape} do
      assert {:ok, _} =
               Kits.add_kit_item(kit, %{
                 description: "Campo cirúrgico",
                 quantity: Decimal.new(2),
                 product_id: drape.id
               })
    end

    test "editing touches nothing already assembled", %{kit: kit, box: box} do
      before = Inventory.balance(box_id: box.id, product_id: kit.product.id)
      [item] = kit.items

      {:ok, _} = Kits.update_kit_item(item, %{quantity: Decimal.new(99)})

      # The kits already built are whatever the ledger says was converted. A
      # recipe is not a claim about them.
      assert Decimal.equal?(
               Inventory.balance(box_id: box.id, product_id: kit.product.id),
               before
             )
    end

    test "assembled_count drops once the kit is written off, same as any product", %{
      kit: kit,
      warehouse: warehouse
    } do
      {:ok, _} =
        EstoqueOS.Outbound.issue_many(
          [%{product_id: kit.product.id, quantity: Decimal.new(2)}],
          %{location_id: warehouse.id, user_id: actor_id(), destination: "pacu"}
        )

      assert Decimal.equal?(Kits.assembled_count(kit), Decimal.new(0))
    end
  end
end
