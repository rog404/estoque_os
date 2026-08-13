defmodule EstoqueOS.AuditingTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Auditing, Inventory}

  alias EstoqueOS.Inventory.Locations

  setup do
    %{warehouse: location_fixture(%{name: "Estoque Principal", kind: "warehouse"})}
  end

  defp stock_in(box, lot, quantity, opts \\ []) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            box_id: box.id,
            location_id: box.location_id,
            quantity: Decimal.new(quantity),
            unit_cost: opts[:unit_cost] && Decimal.new(opts[:unit_cost])
          }
        ]
      })
  end

  defp box_with(warehouse, code, product_attrs, opts \\ []) do
    box = box_fixture(%{code: code, location_id: warehouse.id})
    product = product_fixture(product_attrs)
    lot = lot_fixture(%{product_id: product.id, expires_on: opts[:expires_on]})
    stock_in(box, lot, opts[:quantity] || 10, unit_cost: opts[:unit_cost])

    if opts[:verified_days_ago] do
      box
      |> Ecto.Changeset.change(
        last_verified_at:
          DateTime.add(DateTime.utc_now(:second), -opts[:verified_days_ago] * 24 * 3600, :second)
      )
      |> Repo.update!()
    end

    %{box: Repo.reload!(box), lot: lot, product: product}
  end

  describe "suggestions/1" do
    test "controlled substances come first", %{warehouse: warehouse} do
      %{box: valuable} =
        box_with(warehouse, "ADV1", %{name: "Placa cara"},
          quantity: 100,
          unit_cost: "50.00",
          verified_days_ago: 1
        )

      %{box: controlled} =
        box_with(warehouse, "ADC1", %{name: "Fentanila", controlled: true},
          quantity: 2,
          verified_days_ago: 1
        )

      assert [first, second] = Auditing.suggestions()
      assert first.box.id == controlled.id
      assert second.box.id == valuable.id
      assert first.controlled_count == 1
      assert {:controlled, _} = List.keyfind(first.reasons, :controlled, 0)
    end

    test "then stock that is about to expire", %{warehouse: warehouse} do
      %{box: stale} = box_with(warehouse, "ADO1", %{name: "Gaze"}, verified_days_ago: 200)

      %{box: expiring} =
        box_with(warehouse, "ADX1", %{name: "Soro"},
          expires_on: Date.add(Date.utc_today(), 20),
          verified_days_ago: 1
        )

      assert [first | _rest] = Auditing.suggestions()
      assert first.box.id == expiring.id
      assert first.expiring_count == 1
      refute first.box.id == stale.id
    end

    test "then value at risk", %{warehouse: warehouse} do
      %{box: cheap} =
        box_with(warehouse, "ADH1", %{name: "Abaixador"},
          quantity: 100,
          unit_cost: "0.10",
          verified_days_ago: 5
        )

      %{box: expensive} =
        box_with(warehouse, "ADX9", %{name: "Sugamadex"},
          quantity: 100,
          unit_cost: "41.57",
          verified_days_ago: 5
        )

      assert [first, second] = Auditing.suggestions()
      assert first.box.id == expensive.id
      assert second.box.id == cheap.id
      assert Decimal.equal?(first.value, Decimal.new("4157.000000"))
    end

    test "then whatever has gone longest without a count", %{warehouse: warehouse} do
      %{box: recent} = box_with(warehouse, "ADR1", %{name: "Luva"}, verified_days_ago: 3)
      %{box: forgotten} = box_with(warehouse, "ADO9", %{name: "Avental"}, verified_days_ago: 300)

      assert [first, second] = Auditing.suggestions()
      assert first.box.id == forgotten.id
      assert second.box.id == recent.id
      assert first.days_since_verified >= 300
      assert {:stale, _} = List.keyfind(first.reasons, :stale, 0)
    end

    test "a box nobody ever counted is treated as long overdue", %{warehouse: warehouse} do
      %{box: never} = box_with(warehouse, "ADN1", %{name: "Compressa"})
      box_with(warehouse, "ADR2", %{name: "Seringa"}, verified_days_ago: 10)

      assert [first | _] = Auditing.suggestions()
      assert first.box.id == never.id
      assert first.never_counted
      assert {:never_counted, _} = List.keyfind(first.reasons, :never_counted, 0)
    end

    test "empty boxes are not worth opening", %{warehouse: warehouse} do
      box_fixture(%{code: "ADE1", location_id: warehouse.id})
      %{box: full} = box_with(warehouse, "ADF1", %{name: "Gaze"})

      assert [only] = Auditing.suggestions()
      assert only.box.id == full.id
    end

    test "explains itself", %{warehouse: warehouse} do
      box_with(warehouse, "ADM1", %{name: "Midazolam", controlled: true},
        expires_on: Date.add(Date.utc_today(), 10)
      )

      assert [suggestion] = Auditing.suggestions()
      kinds = Enum.map(suggestion.reasons, &elem(&1, 0))

      assert :controlled in kinds
      assert :expiring in kinds
      assert :never_counted in kinds
    end
  end

  describe "record_count/3" do
    setup %{warehouse: warehouse} do
      %{box: box, lot: lot} = box_with(warehouse, "AD01", %{name: "Eletrodo"}, quantity: 300)
      %{box: box, lot: lot}
    end

    test "posts the difference and stamps the box as verified", %{box: box, lot: lot} do
      assert {:ok, result} = Auditing.record_count(box, %{lot.id => "287"}, user_id: actor_id())

      assert result.adjusted == 1
      assert result.transaction.type == "adjustment"
      assert result.transaction.reason_code == "count_correction"
      assert [entry] = result.transaction.entries
      assert Decimal.equal?(entry.quantity, Decimal.new(-13))

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(287))
      assert result.box.last_verified_at
    end

    test "a count that agrees writes no transaction but still verifies the box", %{
      box: box,
      lot: lot
    } do
      assert {:ok, result} = Auditing.record_count(box, %{lot.id => "300"}, user_id: actor_id())

      assert result.transaction == nil
      assert result.adjusted == 0
      assert result.box.last_verified_at
    end

    test "finding something unexpected brings it into the box", %{box: box, warehouse: warehouse} do
      surprise = lot_fixture(%{product_id: product_fixture().id})
      other_box = box_fixture(%{code: "AD04", location_id: warehouse.id})
      stock_in(other_box, surprise, 5)

      assert {:ok, result} =
               Auditing.record_count(box, %{surprise.id => "5"}, user_id: actor_id())

      assert result.adjusted == 1

      assert Decimal.equal?(
               Inventory.balance(lot_id: surprise.id, box_id: box.id),
               Decimal.new(5)
             )

      # The other box still holds its own; a count states what is here, not
      # what is missing elsewhere.
      assert Decimal.equal?(
               Inventory.balance(lot_id: surprise.id, box_id: other_box.id),
               Decimal.new(5)
             )
    end

    test "lots left off the sheet keep what the ledger presumed", %{box: box, lot: lot} do
      other = lot_fixture(%{product_id: product_fixture().id})
      stock_in(box, other, 40)

      {:ok, _} = Auditing.record_count(box, %{lot.id => "300"}, user_id: actor_id())

      assert Decimal.equal?(Inventory.balance(lot_id: other.id, box_id: box.id), Decimal.new(40))
    end

    test "counting zero empties the position", %{box: box, lot: lot} do
      assert {:ok, _} = Auditing.record_count(box, %{lot.id => "0"}, user_id: actor_id())

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, box_id: box.id), Decimal.new(0))
      assert Locations.box_contents(box) == []
    end

    test "accepts a quantity typed with a comma", %{box: box, lot: lot} do
      assert {:ok, _} = Auditing.record_count(box, %{lot.id => "299,5"}, user_id: actor_id())

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new("299.5"))
    end
  end

  describe "count_sheet/1" do
    test "lists what the ledger presumes is in the box", %{warehouse: warehouse} do
      %{box: box, lot: lot} = box_with(warehouse, "AD01", %{name: "Eletrodo"}, quantity: 300)

      assert [row] = Auditing.count_sheet(box)
      assert row.lot_id == lot.id
      assert Decimal.equal?(row.quantity, Decimal.new(300))
    end
  end
end
