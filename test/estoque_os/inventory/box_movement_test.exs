defmodule EstoqueOS.Inventory.BoxMovementTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  alias EstoqueOS.Inventory.Locations

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    transit = location_fixture(%{name: "Trânsito", kind: "transit"})
    annex = location_fixture(%{name: "Anexo SP", kind: "warehouse"})

    box = box_fixture(%{code: "BM01", location_id: warehouse.id})
    product = product_fixture(%{name: "Eletrodo ECG adulto"})
    lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-03-31]})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            box_id: box.id,
            location_id: warehouse.id,
            quantity: Decimal.new(300),
            unit_cost: Decimal.new("0.2695")
          }
        ]
      })

    %{
      warehouse: warehouse,
      mission: mission,
      transit: transit,
      annex: annex,
      box: box,
      product: product,
      lot: lot
    }
  end

  describe "box lookup by code" do
    test "resolve_box/3 finds the box whatever the case typed", %{
      warehouse: warehouse,
      box: box
    } do
      assert {:ok, found} = Locations.resolve_box("bm01", warehouse.id)
      assert found.id == box.id
    end

    test "get_box_by_code/1 ignores case and padding", %{box: box} do
      assert Locations.get_box_by_code("  bm01 ").id == box.id
      assert Locations.get_box_by_code("") == nil
    end
  end

  describe "move_box/3" do
    test "moves the contents with the box", %{box: box, annex: annex, warehouse: warehouse} do
      assert {:ok, %{box: moved, transaction: transaction}} =
               Locations.move_box(box, annex.id, user_id: actor_id())

      assert moved.location_id == annex.id
      assert transaction.type == "transfer"
      assert transaction.source_location_id == warehouse.id
      assert transaction.destination_location_id == annex.id

      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(0))
      assert Decimal.equal?(Inventory.balance(location_id: annex.id), Decimal.new(300))
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(300))
    end

    test "does not pretend the box was recounted", %{box: box, annex: annex} do
      assert box.last_verified_at == nil

      {:ok, %{box: moved}} = Locations.move_box(box, annex.id, user_id: actor_id())

      assert moved.last_verified_at == nil
    end

    # Only the load-out records which trip a box belongs to, so only it may
    # send a box to a mission or into transit.
    test "refuses to drop a box at a mission by hand", %{box: box, mission: mission} do
      assert {:error, :load_out_required} =
               Locations.move_box(box, mission.id, user_id: actor_id())

      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(0))
    end

    test "refuses to park a box in transit by hand", %{box: box, transit: transit} do
      assert {:error, :load_out_required} =
               Locations.move_box(box, transit.id, user_id: actor_id())
    end

    test "goes straight from one mission to the next, through the load-out", %{
      box: box,
      warehouse: warehouse,
      mission: mission
    } do
      next_mission = location_fixture(%{name: "Missão Coari", kind: "mission_site"})

      {:ok, _} =
        Outbound.load_out(%{
          source_location_id: warehouse.id,
          destination_location_id: mission.id,
          box_ids: [box.id],
          user_id: actor_id()
        })

      {:ok, _} =
        Outbound.load_out(%{
          source_location_id: mission.id,
          destination_location_id: next_mission.id,
          box_ids: [box.id],
          user_id: actor_id()
        })

      box = Locations.get_box!(box.id)

      assert box.location_id == next_mission.id
      assert Decimal.equal?(Inventory.balance(location_id: next_mission.id), Decimal.new(300))
      assert box.last_verified_at == nil
    end

    test "an empty box just changes address", %{annex: annex, warehouse: warehouse} do
      empty = box_fixture(%{code: "BM04", location_id: warehouse.id})

      assert {:ok, %{box: moved, transaction: nil}} =
               Locations.move_box(empty, annex.id, user_id: actor_id())

      assert moved.location_id == annex.id
    end

    test "refuses to move a box to where it already is", %{box: box, warehouse: warehouse} do
      assert {:error, :same_location} = Locations.move_box(box, warehouse.id, user_id: actor_id())
    end

    test "keeps every lot separate when the box holds several", %{
      box: box,
      product: product,
      warehouse: warehouse,
      annex: annex
    } do
      other_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-01-31]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: other_lot.id,
              box_id: box.id,
              location_id: warehouse.id,
              quantity: Decimal.new(40)
            }
          ]
        })

      {:ok, _} = Locations.move_box(box, annex.id, user_id: actor_id())

      assert Decimal.equal?(
               Inventory.balance(lot_id: other_lot.id, location_id: annex.id),
               Decimal.new(40)
             )

      assert [first, second] = Locations.box_contents(box)
      assert first.lot_id != second.lot_id
      assert Enum.all?([first, second], &(&1.location_id == annex.id))
    end
  end

  describe "box_contents/1" do
    test "reports what the box is presumed to hold", %{box: box, lot: lot} do
      assert [row] = Locations.box_contents(box)

      assert row.lot_id == lot.id
      assert row.product == "Eletrodo ECG adulto"
      assert Decimal.equal?(row.quantity, Decimal.new(300))
    end

    test "leaves emptied positions out", %{box: box, lot: lot, warehouse: warehouse} do
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              box_id: box.id,
              location_id: warehouse.id,
              quantity: Decimal.new(-300)
            }
          ]
        })

      assert Locations.box_contents(box) == []
    end
  end

  describe "list_boxes_with_contents/0" do
    test "shows where each box is and how much it holds", %{box: box, warehouse: warehouse} do
      box_fixture(%{code: "BM04", location_id: warehouse.id})

      assert [full, empty] = Locations.list_boxes_with_contents()

      assert full.box.id == box.id
      assert Decimal.equal?(full.quantity, Decimal.new(300))
      assert full.positions == 1

      assert empty.box.code == "BM04"
      assert Decimal.equal?(empty.quantity, Decimal.new(0))
    end
  end

  describe "mark_box_verified/1" do
    test "records a check without touching quantities", %{box: box, lot: lot} do
      assert {:ok, verified} = Locations.mark_box_verified(box)

      assert verified.last_verified_at
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(300))
    end
  end
end
