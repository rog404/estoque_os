defmodule EstoqueOS.ReturnsTest do
  @moduledoc """
  Manual issue and the return of a mission — the messiest moment in the
  operation, where things come back in different boxes than they left in and
  part of the load simply does not come back at all.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    mission_box = box_fixture(%{code: "RT01", location_id: mission.id})
    warehouse_box = box_fixture(%{code: "RT04", location_id: warehouse.id})

    product = product_fixture(%{name: "Eletrodo ECG adulto"})
    sooner = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-12-31]})
    later = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-12-31]})

    stock_in(sooner, mission, 100, box_id: mission_box.id)
    stock_in(later, mission, 50)

    %{
      warehouse: warehouse,
      mission: mission,
      mission_box: mission_box,
      warehouse_box: warehouse_box,
      product: product,
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

  describe "issue/3" do
    test "takes stock out, oldest expiry first", %{
      mission: mission,
      product: product,
      sooner: sooner
    } do
      assert {:ok, transaction} =
               Outbound.issue(product.id, 30, %{
                 location_id: mission.id,
                 notes: "Triagem",
                 user_id: actor_id()
               })

      assert transaction.type == "manual_out"
      assert transaction.notes == "Triagem"
      assert Decimal.equal?(Inventory.balance(lot_id: sooner.id), Decimal.new(70))
    end

    test "spills into the next lot when the first runs out", %{
      mission: mission,
      product: product,
      sooner: sooner,
      later: later
    } do
      {:ok, _} = Outbound.issue(product.id, 120, %{location_id: mission.id, user_id: actor_id()})

      assert Decimal.equal?(Inventory.balance(lot_id: sooner.id), Decimal.new(0))
      assert Decimal.equal?(Inventory.balance(lot_id: later.id), Decimal.new(30))
    end

    test "records which box the goods left", %{
      mission: mission,
      product: product,
      mission_box: box
    } do
      {:ok, transaction} =
        Outbound.issue(product.id, 10, %{location_id: mission.id, user_id: actor_id()})

      assert [entry] = transaction.entries
      assert entry.box_id == box.id
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(90))
    end

    test "refuses to issue more than there is", %{mission: mission, product: product} do
      assert {:error, {:insufficient_stock, %{missing: missing}}} =
               Outbound.issue(product.id, 200, %{location_id: mission.id, user_id: actor_id()})

      assert Decimal.equal?(missing, Decimal.new(50))
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(150))
    end

    test "refuses a quantity of zero", %{mission: mission, product: product} do
      assert {:error, :invalid_quantity} =
               Outbound.issue(product.id, 0, %{location_id: mission.id, user_id: actor_id()})
    end
  end

  describe "plan_return/1" do
    test "lists what the ledger believes is still there, per position", %{
      mission: mission,
      mission_box: box
    } do
      plan = Outbound.plan_return(mission.id)

      assert length(plan) == 2
      boxed = Enum.find(plan, &(&1.box_id == box.id))
      loose = Enum.find(plan, &is_nil(&1.box_id))

      assert boxed.box_code == "RT01"
      assert Decimal.equal?(boxed.expected, Decimal.new(100))
      assert Decimal.equal?(loose.expected, Decimal.new(50))
    end
  end

  describe "receive_return/1" do
    test "brings goods back into a different box", %{
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      warehouse_box: warehouse_box,
      sooner: sooner
    } do
      assert {:ok, %{return: transaction}} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id,
                 lines: [
                   %{
                     lot_id: sooner.id,
                     from_box_id: mission_box.id,
                     to_box_id: warehouse_box.id,
                     quantity: "100",
                     expected: "100"
                   }
                 ]
               })

      assert transaction.type == "return_in"
      assert Decimal.equal?(Inventory.balance(box_id: warehouse_box.id), Decimal.new(100))
      assert Decimal.equal?(Inventory.balance(box_id: mission_box.id), Decimal.new(0))
    end

    test "writes off what did not come back as used in the mission", %{
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      sooner: sooner
    } do
      assert {:ok, %{return: returned, consumed: consumed}} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id,
                 consume_missing: true,
                 lines: [
                   %{
                     lot_id: sooner.id,
                     from_box_id: mission_box.id,
                     quantity: "60",
                     expected: "100"
                   }
                 ]
               })

      assert returned.type == "return_in"
      assert consumed.type == "manual_out"

      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(60))
      # Nothing of that lot is left on the mission's books.
      assert Decimal.equal?(
               Inventory.balance(lot_id: sooner.id, location_id: mission.id),
               Decimal.new(0)
             )
    end

    test "leaves the missing goods on the mission's books when asked not to write them off", %{
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      sooner: sooner
    } do
      assert {:ok, %{consumed: nil}} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id,
                 lines: [
                   %{
                     lot_id: sooner.id,
                     from_box_id: mission_box.id,
                     quantity: "60",
                     expected: "100"
                   }
                 ]
               })

      # The 40 that did not come back are still someone's to explain.
      assert Decimal.equal?(
               Inventory.balance(lot_id: sooner.id, location_id: mission.id),
               Decimal.new(40)
             )
    end

    test "accepts a return of nothing at all from a line", %{
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      sooner: sooner
    } do
      assert {:ok, %{return: nil, consumed: consumed}} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id,
                 consume_missing: true,
                 lines: [
                   %{
                     lot_id: sooner.id,
                     from_box_id: mission_box.id,
                     quantity: "0",
                     expected: "100"
                   }
                 ]
               })

      assert consumed.type == "manual_out"
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(50))
    end

    test "returns loose stock into a box", %{
      mission: mission,
      warehouse: warehouse,
      warehouse_box: warehouse_box,
      later: later
    } do
      {:ok, _} =
        Outbound.receive_return(%{
          user_id: actor_id(),
          source_location_id: mission.id,
          destination_location_id: warehouse.id,
          lines: [
            %{lot_id: later.id, to_box_id: warehouse_box.id, quantity: "50", expected: "50"}
          ]
        })

      assert Decimal.equal?(Inventory.balance(box_id: warehouse_box.id), Decimal.new(50))
    end

    test "refuses to return more than the mission holds", %{
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      sooner: sooner
    } do
      assert {:error, {:negative_stock, _positions}} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id,
                 lines: [
                   %{
                     lot_id: sooner.id,
                     from_box_id: mission_box.id,
                     quantity: "101",
                     expected: "100"
                   }
                 ]
               })

      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(150))
    end

    test "treats a blank box choice as no box", %{
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      sooner: sooner
    } do
      assert {:ok, _} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id,
                 lines: [
                   %{
                     "lot_id" => "#{sooner.id}",
                     "from_box_id" => "#{mission_box.id}",
                     "to_box_id" => "",
                     "quantity" => "100",
                     "expected" => "100"
                   }
                 ]
               })

      assert Decimal.equal?(
               Inventory.balance(location_id: warehouse.id, box_id: nil),
               Decimal.new(100)
             )
    end

    test "refuses an empty return", %{mission: mission, warehouse: warehouse} do
      assert {:error, :nothing_returned} =
               Outbound.receive_return(%{
                 user_id: actor_id(),
                 source_location_id: mission.id,
                 destination_location_id: warehouse.id
               })
    end
  end
end
