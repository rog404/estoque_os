defmodule EstoqueOS.InventoryTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{StockSnapshot, Transaction, TransactionEntry}

  setup do
    warehouse = location_fixture(%{kind: "warehouse"})
    product = product_fixture()
    lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-07-31]})

    %{warehouse: warehouse, product: product, lot: lot}
  end

  defp purchase(lot, location, quantity, opts \\ []) do
    Inventory.post_transaction(%{
      type: "purchase_in",
      user_id: actor_id(),
      entries: [
        %{
          lot_id: lot.id,
          location_id: location.id,
          box_id: opts[:box_id],
          quantity: Decimal.new(quantity),
          unit_cost: opts[:unit_cost]
        }
      ]
    })
  end

  describe "post_transaction/1" do
    test "appends entries and derives the balance from them", %{lot: lot, warehouse: warehouse} do
      assert {:ok, transaction} = purchase(lot, warehouse, 250, unit_cost: Decimal.new("0.5220"))
      assert [entry] = transaction.entries

      assert Decimal.equal?(entry.quantity, Decimal.new(250))
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(250))
    end

    test "the balance is the sum of every entry", %{lot: lot, warehouse: warehouse} do
      {:ok, _} = purchase(lot, warehouse, 100)
      {:ok, _} = purchase(lot, warehouse, 50)

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-30)}
          ]
        })

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(120))

      ledger_sum =
        TransactionEntry
        |> where([e], e.lot_id == ^lot.id)
        |> Repo.all()
        |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.quantity))

      assert Decimal.equal?(ledger_sum, Decimal.new(120))
    end

    test "keeps the snapshot cache in step with the ledger", %{lot: lot, warehouse: warehouse} do
      {:ok, _} = purchase(lot, warehouse, 100)
      {:ok, _} = purchase(lot, warehouse, 25)

      assert Decimal.equal?(
               Inventory.cached_balance(lot_id: lot.id),
               Inventory.balance(lot_id: lot.id)
             )

      assert [%StockSnapshot{}] = Repo.all(StockSnapshot)
    end

    test "recalculating the snapshots changes nothing", %{lot: lot, warehouse: warehouse} do
      {:ok, _} = purchase(lot, warehouse, 100)
      {:ok, _} = purchase(lot, warehouse, 7)

      before = Inventory.cached_balance(lot_id: lot.id)
      assert {:ok, _count} = Inventory.recalculate_snapshots()

      assert Decimal.equal?(Inventory.cached_balance(lot_id: lot.id), before)

      assert Decimal.equal?(
               Inventory.cached_balance(lot_id: lot.id),
               Inventory.balance(lot_id: lot.id)
             )
    end

    test "snapshots are kept per box", %{lot: lot, warehouse: warehouse} do
      box_a = box_fixture(%{location_id: warehouse.id})
      box_b = box_fixture(%{location_id: warehouse.id})

      {:ok, _} = purchase(lot, warehouse, 10, box_id: box_a.id)
      {:ok, _} = purchase(lot, warehouse, 4, box_id: box_b.id)

      assert Decimal.equal?(Inventory.balance(box_id: box_a.id), Decimal.new(10))
      assert Decimal.equal?(Inventory.balance(box_id: box_b.id), Decimal.new(4))
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(14))
    end

    test "refuses to drive stock negative", %{lot: lot, warehouse: warehouse} do
      {:ok, _} = purchase(lot, warehouse, 10)

      assert {:error, {:negative_stock, [{lot_id, nil, location_id}]}} =
               Inventory.post_transaction(%{
                 type: "manual_out",
                 user_id: actor_id(),
                 entries: [
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-11)}
                 ]
               })

      assert lot_id == lot.id
      assert location_id == warehouse.id
      # The failed attempt left nothing behind.
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(10))
      assert Decimal.equal?(Inventory.cached_balance(lot_id: lot.id), Decimal.new(10))
    end

    test "an adjustment may drive stock negative, with a reason", %{
      lot: lot,
      warehouse: warehouse
    } do
      assert {:ok, _} =
               Inventory.post_transaction(%{
                 type: "adjustment",
                 user_id: actor_id(),
                 reason_code: "count_correction",
                 entries: [
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-5)}
                 ]
               })

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(-5))
    end

    test "correcting stock downwards appends, it never rewrites", %{
      lot: lot,
      warehouse: warehouse
    } do
      {:ok, purchase} = purchase(lot, warehouse, 10)
      original = Repo.all(from e in TransactionEntry, order_by: e.id)

      {:ok, _correction} =
        Inventory.post_transaction(%{
          type: "adjustment",
          user_id: actor_id(),
          reason_code: "count_correction",
          entries: [%{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-4)}]
        })

      after_correction = Repo.all(from e in TransactionEntry, order_by: e.id)

      # The ledger is a journal: the entry that said 10 still says 10, and the
      # correction sits after it. Editing the first row would erase the fact that
      # ten were ever received, and with it any way to ask why six remain.
      assert Enum.take(after_correction, length(original)) == original
      assert length(after_correction) == length(original) + 1
      assert Repo.get(Transaction, purchase.id)
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(6))
      assert Decimal.equal?(Inventory.cached_balance(lot_id: lot.id), Decimal.new(6))
    end

    test "rolls back completely when one entry is invalid", %{lot: lot, warehouse: warehouse} do
      assert {:error, changeset} =
               Inventory.post_transaction(%{
                 type: "purchase_in",
                 user_id: actor_id(),
                 entries: [
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(10)},
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(0)}
                 ]
               })

      refute changeset.valid?
      assert Repo.all(TransactionEntry) == []
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(0))
    end

    test "a transfer moves stock between locations", %{lot: lot, warehouse: warehouse} do
      mission = location_fixture(%{kind: "mission_site"})
      {:ok, _} = purchase(lot, warehouse, 100)

      assert {:ok, _} =
               Inventory.post_transaction(%{
                 type: "transfer",
                 user_id: actor_id(),
                 source_location_id: warehouse.id,
                 destination_location_id: mission.id,
                 entries: [
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-40)},
                   %{lot_id: lot.id, location_id: mission.id, quantity: Decimal.new(40)}
                 ]
               })

      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(60))
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(40))
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(100))
    end

    test "donations may be posted without a unit cost", %{lot: lot, warehouse: warehouse} do
      assert {:ok, transaction} =
               Inventory.post_transaction(%{
                 type: "donation_in",
                 user_id: actor_id(),
                 entries: [
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(12)}
                 ]
               })

      assert [%{unit_cost: nil}] = transaction.entries
    end
  end

  describe "enter_manually/1" do
    test "refuses a box that sits at another location", %{product: product, warehouse: warehouse} do
      elsewhere = location_fixture(%{name: "Escritório SP"})
      box = box_fixture(%{location_id: elsewhere.id})

      assert {:error, :box_elsewhere} =
               Inventory.enter_manually(%{
                 product_id: product.id,
                 location_id: warehouse.id,
                 box_id: box.id,
                 quantity: "3",
                 user_id: actor_id()
               })

      # The same goods would otherwise count twice — at the location named on the
      # entry, and in a box that is physically somewhere else.
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(0))
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(0))
    end

    test "accepts a box that is at the location", %{product: product, warehouse: warehouse} do
      box = box_fixture(%{location_id: warehouse.id})

      assert {:ok, _transaction} =
               Inventory.enter_manually(%{
                 product_id: product.id,
                 location_id: warehouse.id,
                 box_id: box.id,
                 quantity: "3",
                 user_id: actor_id()
               })

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(3))
    end
  end

  describe "FEFO" do
    test "orders lots by expiry, unknown expiry last", %{product: product, warehouse: warehouse} do
      later = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-01-31]})
      sooner = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-09-30]})
      undated = lot_fixture(%{product_id: product.id, expires_on: nil})

      for lot <- [later, sooner, undated], do: {:ok, _} = purchase(lot, warehouse, 10)

      assert [first, second, third] = Inventory.lot_balances(product.id)
      assert first.lot_id == sooner.id
      assert second.lot_id == later.id
      assert third.lot_id == undated.id
    end

    test "skips lots that are already empty", %{product: product, warehouse: warehouse} do
      empty = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-01-31]})
      stocked = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-01-31]})

      {:ok, _} = purchase(empty, warehouse, 5)
      {:ok, _} = purchase(stocked, warehouse, 5)

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          user_id: actor_id(),
          entries: [%{lot_id: empty.id, location_id: warehouse.id, quantity: Decimal.new(-5)}]
        })

      assert [%{lot_id: lot_id}] = Inventory.lot_balances(product.id)
      assert lot_id == stocked.id
    end

    test "suggests picks across lots until the quantity is met", %{
      product: product,
      warehouse: warehouse
    } do
      sooner = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-09-30]})
      later = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-09-30]})

      {:ok, _} = purchase(sooner, warehouse, 30)
      {:ok, _} = purchase(later, warehouse, 100)

      assert {:ok, [first, second]} = Inventory.suggest_fefo_picks(product.id, 50)
      assert first.lot_id == sooner.id
      assert Decimal.equal?(first.take, Decimal.new(30))
      assert second.lot_id == later.id
      assert Decimal.equal?(second.take, Decimal.new(20))
    end

    test "reports how much is missing when stock is short", %{
      product: product,
      warehouse: warehouse
    } do
      lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-09-30]})
      {:ok, _} = purchase(lot, warehouse, 5)

      assert {:insufficient_stock, [pick], missing} =
               Inventory.suggest_fefo_picks(product.id, 20)

      assert Decimal.equal?(pick.take, Decimal.new(5))
      assert Decimal.equal?(missing, Decimal.new(15))
    end

    test "a box_id opt narrows positions to that box alone", %{
      product: product,
      warehouse: warehouse
    } do
      near = box_fixture(%{location_id: warehouse.id})
      far = box_fixture(%{location_id: warehouse.id})

      near_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-09-30]})
      far_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-06-30]})

      {:ok, _} = purchase(near_lot, warehouse, 10, box_id: near.id)
      {:ok, _} = purchase(far_lot, warehouse, 10, box_id: far.id)

      # Without a box_id, the box expiring soonest is reached for first.
      assert {:ok, [pick]} =
               Inventory.suggest_fefo_positions(product.id, 10, location_id: warehouse.id)

      assert pick.box_id == near.id

      # With a box_id, only that box is looked at — even one that is not the
      # one FEFO would have reached for on its own.
      assert {:ok, [pick]} =
               Inventory.suggest_fefo_positions(product.id, 10,
                 location_id: warehouse.id,
                 box_id: far.id
               )

      assert pick.box_id == far.id

      assert {:insufficient_stock, [], missing} =
               Inventory.suggest_fefo_positions(product.id, 1,
                 location_id: warehouse.id,
                 box_id: nil,
                 loose_only: true
               )

      assert Decimal.equal?(missing, Decimal.new(1))
    end
  end

  describe "box_quantities/3" do
    test "groups a product's stock by box, loose stock last", %{
      product: product,
      warehouse: warehouse
    } do
      lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-01-31]})
      box = box_fixture(%{location_id: warehouse.id})

      {:ok, _} = purchase(lot, warehouse, 3)
      {:ok, _} = purchase(lot, warehouse, 7, box_id: box.id)

      rows = Inventory.box_quantities(product.id, warehouse.id) |> Enum.sort_by(& &1.box_code)

      assert [%{box_code: nil, quantity: loose}, %{box_code: code, quantity: boxed}] = rows
      assert Decimal.equal?(loose, Decimal.new(3))
      assert code == box.code
      assert Decimal.equal?(boxed, Decimal.new(7))
    end

    test "skips a box emptied back out", %{product: product, warehouse: warehouse} do
      lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-01-31]})
      box = box_fixture(%{location_id: warehouse.id})

      {:ok, _} = purchase(lot, warehouse, 5, box_id: box.id)

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(-5)
            }
          ]
        })

      assert Inventory.box_quantities(product.id, warehouse.id) == []
    end
  end
end
