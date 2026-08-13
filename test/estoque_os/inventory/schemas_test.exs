defmodule EstoqueOS.Inventory.SchemasTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory.{Box, Location, Lot, Transaction, TransactionEntry}

  describe "lot" do
    test "the same lot number cannot repeat for a product" do
      product = product_fixture()
      lot_fixture(%{product_id: product.id, lot_number: "BD-057/25M"})

      assert {:error, changeset} =
               %Lot{}
               |> Lot.changeset(%{product_id: product.id, lot_number: "BD-057/25M"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).product_id
    end

    test "a product has at most one unknown-lot placeholder" do
      product = product_fixture()
      assert %Lot{lot_number: nil} = lot_fixture(%{product_id: product.id, lot_number: nil})

      assert {:error, changeset} =
               %Lot{}
               |> Lot.changeset(%{product_id: product.id, lot_number: "  ", needs_review: true})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).product_id
    end

    test "unknown?/1 flags the placeholder" do
      assert Lot.unknown?(lot_fixture(%{lot_number: nil}))
      refute Lot.unknown?(lot_fixture())
    end

    test "rejects an expiry before the manufacturing date" do
      changeset =
        Lot.changeset(%Lot{}, %{
          product_id: product_fixture().id,
          lot_number: "X",
          manufactured_on: ~D[2026-01-01],
          expires_on: ~D[2025-01-01]
        })

      refute changeset.valid?
      assert errors_on(changeset).expires_on != []
    end
  end

  describe "location" do
    test "rejects an unknown kind" do
      changeset = Location.changeset(%Location{}, %{name: "X", kind: "spaceship"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).kind
    end

    test "nests under a parent" do
      warehouse = location_fixture(%{kind: "warehouse"})
      room = location_fixture(%{kind: "mission_site", parent_id: warehouse.id})

      assert room.parent_id == warehouse.id
    end
  end

  describe "box" do
    test "codes are upcased and unique" do
      box = box_fixture(%{code: "sc01"})
      assert box.code == "SC01"

      assert {:error, changeset} =
               %Box{}
               |> Box.changeset(%{code: "SC01", location_id: location_fixture().id})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).code
    end
  end

  describe "transaction" do
    test "an adjustment must carry a reason code" do
      changeset = Transaction.changeset(%Transaction{}, %{type: "adjustment", entries: []})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).reason_code
    end

    test "an adjustment rejects an unknown reason code" do
      changeset =
        Transaction.changeset(%Transaction{}, %{
          type: "adjustment",
          reason_code: "because",
          entries: []
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).reason_code
    end

    test "a transfer needs both locations" do
      changeset =
        Transaction.changeset(%Transaction{}, %{
          type: "transfer",
          source_location_id: location_fixture().id,
          entries: []
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).destination_location_id
    end

    test "requires at least one entry" do
      changeset = Transaction.changeset(%Transaction{}, %{type: "purchase_in", entries: []})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).entries
    end

    test "defaults occurred_at to now" do
      changeset = Transaction.changeset(%Transaction{}, %{type: "purchase_in", entries: []})

      assert %DateTime{} = Ecto.Changeset.get_field(changeset, :occurred_at)
    end

    test "rejects an unknown type" do
      changeset = Transaction.changeset(%Transaction{}, %{type: "teleport", entries: []})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).type
    end
  end

  describe "transaction entry" do
    test "rejects a zero quantity" do
      changeset =
        TransactionEntry.changeset(%TransactionEntry{}, %{
          quantity: Decimal.new(0),
          lot_id: lot_fixture().id,
          location_id: location_fixture().id
        })

      refute changeset.valid?
      assert "must not be zero" in errors_on(changeset).quantity
    end

    test "accepts a null unit cost but never a zero one" do
      base = %{
        quantity: Decimal.new(1),
        lot_id: lot_fixture().id,
        location_id: location_fixture().id
      }

      assert TransactionEntry.changeset(%TransactionEntry{}, base).valid?

      changeset =
        TransactionEntry.changeset(%TransactionEntry{}, Map.put(base, :unit_cost, Decimal.new(0)))

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).unit_cost
    end
  end
end
