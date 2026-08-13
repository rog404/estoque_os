defmodule EstoqueOS.ReportsTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Reports}
  alias EstoqueOS.Reports.StockWorkbook

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    product = product_fixture(%{name: "Eletrodo ECG adulto"})

    lot =
      lot_fixture(%{product_id: product.id, lot_number: "114391U02", expires_on: ~D[2027-03-31]})

    %{warehouse: warehouse, product: product, lot: lot}
  end

  defp receive_stock(lot, location, quantity, opts \\ []) do
    {:ok, transaction} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity),
            unit_cost: opts[:unit_cost] && Decimal.new(opts[:unit_cost])
          }
        ]
      })

    transaction
  end

  describe "stock_rows/1" do
    test "reports one row per lot, box and location", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 300, unit_cost: "0.2695")

      assert [row] = Reports.stock_rows()
      assert row.product == "Eletrodo ECG adulto"
      assert row.lot_number == "114391U02"
      assert row.expires_on == ~D[2027-03-31]
      assert row.location == "Estoque Principal"
      assert Decimal.equal?(row.quantity, Decimal.new(300))
      assert Decimal.equal?(row.unit_cost, Decimal.new("0.269500"))
      assert Decimal.equal?(row.total, Decimal.new("80.850000"))
    end

    test "averages what we actually paid across entries", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 100, unit_cost: "1.00")
      receive_stock(lot, warehouse, 300, unit_cost: "2.00")

      assert [row] = Reports.stock_rows()
      # (100 * 1 + 300 * 2) / 400
      assert Decimal.equal?(row.unit_cost, Decimal.new("1.750000"))
    end

    test "leaves the cost blank for donations", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 10)

      assert [row] = Reports.stock_rows()
      assert row.unit_cost == nil
      assert row.total == nil
    end

    test "leaves emptied positions out", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 10)

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-10)}
          ]
        })

      assert Reports.stock_rows() == []
    end
  end

  describe "export and import" do
    test "the exported spreadsheet reads back with the same numbers", %{
      lot: lot,
      warehouse: warehouse
    } do
      box = box_fixture(%{code: "RP01", location_id: warehouse.id})
      receive_stock(lot, warehouse, 300, unit_cost: "0.2695", box_id: box.id)

      assert {:ok, binary} = Reports.export_stock()
      assert {:ok, [row]} = StockWorkbook.import_rows(binary)

      assert row.product == "Eletrodo ECG adulto"
      assert row.lot_number == "114391U02"
      assert row.expires_on == ~D[2027-03-31]
      assert row.box == "RP01"
      assert row.location == "Estoque Principal"
      assert Decimal.equal?(row.quantity, Decimal.new(300))
    end

    test "a product name that reads as a formula is escaped, not executed" do
      row = %{
        product: "=cmd|'/c calc'!A1",
        group: nil,
        lot_number: "L1",
        expires_on: nil,
        box: nil,
        location: "Estoque Principal",
        quantity: Decimal.new(1),
        unit_cost: nil,
        total: nil
      }

      assert {:ok, binary} = StockWorkbook.to_xlsx([row])
      assert {:ok, [imported]} = StockWorkbook.import_rows(binary)

      # Elixlsx already writes it as a literal string cell, never a formula —
      # the leading apostrophe is belt-and-suspenders for when the file is
      # reopened in Excel, which would otherwise run it as one.
      assert String.starts_with?(imported.product, "'")
      assert imported.product == "'" <> row.product
    end

    test "re-importing an untouched export changes nothing", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 300, unit_cost: "0.2695")
      {:ok, binary} = Reports.export_stock()

      assert {:ok, result} = Reports.import_stock(binary, user_id: actor_id())
      assert result.counted == 1
      assert result.adjusted == 0
      assert result.transaction == nil

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(300))
    end

    test "a count that disagrees posts only the difference", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 300, unit_cost: "0.2695")

      # The warehouse counted 287 of the 300 the ledger believed in.
      counted =
        counted_sheet([%{product: "Eletrodo ECG adulto", lot: "114391U02", quantity: 287}])

      assert {:ok, result} = Reports.import_stock(counted, user_id: actor_id())
      assert result.adjusted == 1
      assert result.transaction.type == "inventory_import"

      assert [entry] = result.transaction.entries
      assert Decimal.equal?(entry.quantity, Decimal.new(-13))
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(287))
    end

    test "a count of a lot we never saw brings it into stock", %{warehouse: _warehouse} do
      product_fixture(%{name: "Gaze estéril"})

      counted =
        counted_sheet([%{product: "Gaze estéril", lot: "NOVO-1", quantity: 40, box: "RP04"}])

      assert {:ok, result} = Reports.import_stock(counted, user_id: actor_id())
      assert result.adjusted == 1

      assert [row] = Reports.stock_rows() |> Enum.filter(&(&1.product == "Gaze estéril"))
      assert Decimal.equal?(row.quantity, Decimal.new(40))
      # The box existed in the warehouse but not in our database until now.
      assert row.box == "RP04"
    end

    test "nothing is posted when any line is wrong", %{lot: lot, warehouse: warehouse} do
      receive_stock(lot, warehouse, 300, unit_cost: "0.2695")

      counted =
        counted_sheet([
          %{product: "Eletrodo ECG adulto", lot: "114391U02", quantity: 287},
          %{product: "Produto que não existe", lot: "X", quantity: 5},
          %{product: "Eletrodo ECG adulto", lot: "114391U02", quantity: -2}
        ])

      assert {:error, errors} = Reports.import_stock(counted, user_id: actor_id())
      assert [first, second] = errors
      assert first.line == 3
      assert first.message =~ "não está no catálogo"
      assert second.line == 4
      assert second.message =~ "negativa"

      # The good line was not applied either.
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(300))
    end

    test "a spreadsheet without the required columns is refused" do
      binary = sheet([["Coisa", "Valor"], ["Gaze", 10]])

      assert {:error, {:missing_columns, missing}} =
               Reports.import_stock(binary, user_id: actor_id())

      assert "Produto" in missing
      assert "Local" in missing
    end

    test "accepts columns in any order and dates written the Brazilian way" do
      product_fixture(%{name: "Gaze estéril"})
      location_fixture(%{name: "Hospital de Campanha", kind: "mission_site"})

      binary =
        sheet([
          ["Local", "Quantidade", "Produto", "Lote", "Validade"],
          ["Hospital de Campanha", 12, "Gaze estéril", "L-9", "31/12/27"]
        ])

      assert {:ok, result} = Reports.import_stock(binary, user_id: actor_id())
      assert result.adjusted == 1

      lot = Repo.get_by!(EstoqueOS.Inventory.Lot, lot_number: "L-9")
      assert lot.expires_on == ~D[2027-12-31]
    end
  end

  # Builds a spreadsheet shaped like the one we export.
  defp counted_sheet(rows) do
    header = ["Produto", "Grupo", "Lote", "Validade", "Caixa", "Local", "Quantidade"]

    body =
      Enum.map(rows, fn row ->
        [
          row.product,
          "",
          row[:lot] || "",
          "",
          row[:box] || "",
          row[:location] || "Estoque Principal",
          row.quantity
        ]
      end)

    sheet([header | body])
  end

  defp sheet(rows) do
    {:ok, {_name, binary}} =
      %Elixlsx.Workbook{sheets: [%Elixlsx.Sheet{name: "Estoque", rows: rows}]}
      |> Elixlsx.write_to_memory("contagem.xlsx")

    binary
  end
end
