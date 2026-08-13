defmodule EstoqueOS.OutboundTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    transit = location_fixture(%{name: "Trânsito", kind: "transit"})

    box = box_fixture(%{code: "OB01", location_id: warehouse.id})
    product = product_fixture(%{name: "Eletrodo ECG adulto"})

    boxed_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2029-01-31]})
    stock_in(boxed_lot, warehouse, 300, box_id: box.id)

    # Loose stock of the same product, two lots with different expiry dates.
    sooner = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-12-31]})
    later = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-12-31]})
    stock_in(sooner, warehouse, 40)
    stock_in(later, warehouse, 100)

    %{
      warehouse: warehouse,
      mission: mission,
      transit: transit,
      box: box,
      product: product,
      boxed_lot: boxed_lot,
      sooner: sooner,
      later: later
    }
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

  describe "plan/1" do
    test "separates whole boxes from loose stock", %{warehouse: warehouse, box: box} do
      plan = Outbound.plan(warehouse.id)

      assert [only_box] = plan.boxes
      assert only_box.box.id == box.id
      assert Decimal.equal?(only_box.quantity, Decimal.new(300))

      assert length(plan.loose) == 2
      assert Enum.all?(plan.loose, &(&1.product == "Eletrodo ECG adulto"))
    end

    test "lists loose stock oldest expiry first", %{warehouse: warehouse, sooner: sooner} do
      plan = Outbound.plan(warehouse.id)

      assert hd(plan.loose).lot_id == sooner.id
    end

    test "leaves empty boxes out of the load", %{warehouse: warehouse} do
      box_fixture(%{code: "OBE1", location_id: warehouse.id})

      assert length(Outbound.plan(warehouse.id).boxes) == 1
    end
  end

  describe "suggest_picks/3" do
    test "takes the lot that expires first", %{
      warehouse: warehouse,
      product: product,
      sooner: sooner,
      later: later
    } do
      assert {:ok, [first, second]} = Outbound.suggest_picks(product.id, 60, warehouse.id)

      assert first.lot_id == sooner.id
      assert Decimal.equal?(first.take, Decimal.new(40))
      assert second.lot_id == later.id
      assert Decimal.equal?(second.take, Decimal.new(20))
    end

    test "does not raid the boxes for loose picks", %{
      warehouse: warehouse,
      product: product,
      boxed_lot: boxed_lot
    } do
      assert {:insufficient_stock, picks, missing} =
               Outbound.suggest_picks(product.id, 500, warehouse.id)

      refute Enum.any?(picks, &(&1.lot_id == boxed_lot.id))
      # Only the 140 loose units are available to pick by quantity.
      assert Decimal.equal?(missing, Decimal.new(360))
    end
  end

  describe "load_out/1" do
    test "sends a box whole, contents and address", %{
      warehouse: warehouse,
      mission: mission,
      box: box
    } do
      assert {:ok, result} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: mission.id,
                 box_ids: [box.id]
               })

      assert result.transaction.type == "load_out"
      assert result.boxes_moved == 1

      assert Decimal.equal?(
               Inventory.balance(box_id: box.id, location_id: mission.id),
               Decimal.new(300)
             )

      assert Repo.reload!(box).location_id == mission.id
    end

    test "does not pretend the load was counted", %{
      warehouse: warehouse,
      mission: mission,
      box: box
    } do
      {:ok, _} =
        Outbound.load_out(%{
          user_id: actor_id(),
          source_location_id: warehouse.id,
          destination_location_id: mission.id,
          box_ids: [box.id]
        })

      assert Repo.reload!(box).last_verified_at == nil
    end

    test "refuses to send stock that is in no box", %{
      warehouse: warehouse,
      mission: mission,
      sooner: sooner
    } do
      assert {:error, :unboxed_cannot_travel} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: mission.id,
                 picks: [%{lot_id: sooner.id, quantity: "25"}]
               })

      # Goods that leave loose have nothing identifying them at the mission and
      # nothing bringing them back. Sending them is a write-off wearing the
      # clothes of a transfer, so nothing moves.
      assert Decimal.equal?(
               Inventory.balance(lot_id: sooner.id, location_id: mission.id),
               Decimal.new(0)
             )

      assert Decimal.equal?(
               Inventory.balance(lot_id: sooner.id, location_id: warehouse.id),
               Decimal.new(40)
             )
    end

    test "sends every box in one event, leaving the unboxed behind", %{
      warehouse: warehouse,
      mission: mission,
      box: box
    } do
      plan = Outbound.plan(warehouse.id)

      assert {:ok, result} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: mission.id,
                 box_ids: Enum.map(plan.boxes, & &1.box.id)
               })

      assert result.transaction.type == "load_out"
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(300))
      assert Repo.reload!(box).location_id == mission.id

      # What was never boxed stays at the warehouse, waiting for the conference.
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(140))
    end

    test "parks the load in transit on the way", %{
      warehouse: warehouse,
      transit: transit,
      box: box
    } do
      assert {:ok, _} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: transit.id,
                 box_ids: [box.id]
               })

      assert Decimal.equal?(Inventory.balance(location_id: transit.id), Decimal.new(300))
    end

    test "a box that is empty sends nothing rather than a negative", %{
      warehouse: warehouse,
      mission: mission
    } do
      empty = box_fixture(%{code: "LOEM", location_id: warehouse.id})

      assert {:error, :nothing_to_send} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: mission.id,
                 box_ids: [empty.id]
               })
    end

    test "refuses an empty load", %{warehouse: warehouse, mission: mission} do
      assert {:error, :nothing_to_send} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: mission.id
               })
    end

    test "refuses to send stock to where it already is", %{warehouse: warehouse, box: box} do
      assert {:error, :same_location} =
               Outbound.load_out(%{
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: warehouse.id,
                 box_ids: [box.id]
               })
    end
  end
end
