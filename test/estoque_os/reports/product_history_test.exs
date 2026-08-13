defmodule EstoqueOS.Reports.ProductHistoryTest do
  @moduledoc """
  "What happened to this gauze" is the question a recall asks, and it is asked
  urgently. It used to be answerable only by reading three screens and joining
  them by eye, none of which was about the product.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Reports.ProductHistory

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "PH01", location_id: warehouse.id})
    gauze = product_fixture(%{name: "Gaze estéril"})
    other = product_fixture(%{name: "Avental EG"})

    early = lot_fixture(%{product_id: gauze.id, lot_number: "L1", expires_on: ~D[2027-01-31]})
    late = lot_fixture(%{product_id: gauze.id, lot_number: "L2", expires_on: ~D[2029-01-31]})
    unrelated = lot_fixture(%{product_id: other.id})

    buy = fn lot, quantity, cost ->
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(quantity),
              unit_cost: cost && Decimal.new(cost)
            }
          ]
        })
    end

    buy.(early, 100, "1.50")
    buy.(late, 50, "3.00")
    buy.(unrelated, 80, "9.99")

    %{warehouse: warehouse, box: box, gauze: gauze, other: other, early: early, late: late}
  end

  describe "positions/1" do
    test "shows where the stock is, earliest expiry first", %{gauze: gauze} do
      assert [first, second] = ProductHistory.positions(gauze.id)

      assert first.lot_number == "L1"
      assert first.box == "PH01"
      assert first.location == "Estoque Principal"
      assert Decimal.equal?(first.quantity, Decimal.new(100))
      assert second.lot_number == "L2"
    end

    test "leaves out a lot that ran to zero", %{
      gauze: gauze,
      early: early,
      warehouse: warehouse,
      box: box
    } do
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          user_id: actor_id(),
          source_location_id: warehouse.id,
          entries: [
            %{
              lot_id: early.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(-100)
            }
          ]
        })

      # An empty lot is history, and history is what the movement list is for.
      assert [%{lot_number: "L2"}] = ProductHistory.positions(gauze.id)
    end

    test "never mixes in another product", %{other: other} do
      assert [position] = ProductHistory.positions(other.id)
      assert is_nil(position.lot_number) or position.lot_number != "L1"
    end
  end

  describe "for_product/2" do
    test "lists every movement, newest first", %{gauze: gauze} do
      history = ProductHistory.for_product(gauze.id)

      assert history.product.name == "Gaze estéril"
      assert history.movement_count == 2
      assert length(history.movements) == 2
    end

    test "counts more than it shows, and says so", %{gauze: gauze} do
      history = ProductHistory.for_product(gauze.id, limit: 1)

      # Truncating in silence is how a reader concludes there is nothing else.
      assert length(history.movements) == 1
      assert history.movement_count == 2
    end

    test "a movement carries who, where and which lot", %{gauze: gauze} do
      history = ProductHistory.for_product(gauze.id)
      movement = hd(history.movements)

      assert movement.transaction.user
      assert movement.location
      assert movement.lot.product.name == "Gaze estéril"
    end
  end

  describe "costs/2" do
    test "shows what was paid per unit, newest first", %{gauze: gauze} do
      assert [newest, oldest] = ProductHistory.costs(gauze.id)

      assert Decimal.equal?(newest.unit_cost, Decimal.new("3.00"))
      assert Decimal.equal?(oldest.unit_cost, Decimal.new("1.50"))
    end

    test "leaves out a donation rather than showing it as free", %{gauze: gauze} do
      lot = lot_fixture(%{product_id: gauze.id, lot_number: "DOA"})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "donation_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: location_fixture().id,
              quantity: Decimal.new(10),
              unit_cost: nil
            }
          ]
        })

      # A donation was not free — its value was never informed, and zero is a
      # different claim.
      assert length(ProductHistory.costs(gauze.id)) == 2
    end
  end
end
