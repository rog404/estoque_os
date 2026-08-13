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
    # A second warehouse: the moves a person may still make by hand.
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

      # Moving a box tells us nothing new about what is inside it.
      assert moved.last_verified_at == nil
    end

    # A box arriving at a mission, or entering transit, is the moment the
    # movement acquires a reason — which trip it belongs to. Only the load-out
    # asks, so only the load-out may put it there. SPEC §4.3 still holds: the
    # move is cheap and forces no recount. It just goes through the door that
    # records the mission.
    test "refuses to drop a box at a mission by hand", %{box: box, mission: mission} do
      assert {:error, :load_out_required} =
               Locations.move_box(box, mission.id, user_id: actor_id())

      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(0))
    end

    test "refuses to park a box in transit by hand", %{box: box, transit: transit} do
      assert {:error, :load_out_required} =
               Locations.move_box(box, transit.id, user_id: actor_id())
    end

    # SPEC §4.3: mission to mission, no recount along the way. The load-out is
    # how it happens now, and it attributes the goods to the trip they left for.
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
      # No recount was demanded along the way.
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
