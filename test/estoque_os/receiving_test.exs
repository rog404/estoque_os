defmodule EstoqueOS.ReceivingTest do
  # Not async: imports the same real invoice as the other invoice suites, which
  # would race on the supplier's unique CNPJ index.
  use EstoqueOS.DataCase, async: false

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Invoices, Receiving}
  alias EstoqueOS.Receiving.ReceiptLine
  alias EstoqueOS.Repo

  @samples Path.expand("../../samples", __DIR__)
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    {:ok, invoice} =
      @samples |> Path.join(@atlantica) |> File.read!() |> Invoices.import_document()

    # Resolve every line the way the confirmation screen would.
    Enum.each(invoice.items, fn item ->
      product = product_fixture(%{name: "Produto #{item.item_number}"})

      {:ok, _} =
        Invoices.resolve_item(item, %{
          product_id: product.id,
          conversion_factor: Decimal.to_string(item.conversion_factor)
        })
    end)

    invoice = Invoices.get_invoice!(invoice.id)

    %{warehouse: warehouse, invoice: invoice}
  end

  defp post!(invoice, warehouse) do
    {:ok, %{invoice: posted}} =
      Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

    posted
  end

  defp line_for(receipt, item_number) do
    Enum.find(receipt.lines, &(&1.invoice_item.item_number == item_number))
  end

  describe "start_receipt/2" do
    test "opens a round with one line per invoice item", %{
      invoice: invoice,
      warehouse: warehouse
    } do
      posted = post!(invoice, warehouse)

      assert {:ok, receipt} =
               Receiving.start_receipt(posted, %{location_id: warehouse.id})

      assert receipt.round == 1
      assert receipt.status == "draft"
      assert length(receipt.lines) == 4

      # 6 packs of 50 electrodes is 300 units expected.
      assert Decimal.equal?(line_for(receipt, 1).expected_quantity, Decimal.new(300))
      assert Enum.all?(receipt.lines, &is_nil(&1.counted_quantity))
    end

    test "refuses an invoice that was never posted", %{invoice: invoice, warehouse: warehouse} do
      assert {:error, :invoice_not_posted} =
               Receiving.start_receipt(invoice, %{location_id: warehouse.id})
    end

    test "refuses a second round while one is open", %{invoice: invoice, warehouse: warehouse} do
      posted = post!(invoice, warehouse)
      {:ok, _} = Receiving.start_receipt(posted, %{location_id: warehouse.id})

      assert {:error, :receipt_already_open} =
               Receiving.start_receipt(posted, %{location_id: warehouse.id})
    end
  end

  describe "counting" do
    setup %{invoice: invoice, warehouse: warehouse} do
      posted = post!(invoice, warehouse)
      {:ok, receipt} = Receiving.start_receipt(posted, %{location_id: warehouse.id})

      %{receipt: receipt, posted: posted}
    end

    test "records a count and a box", %{receipt: receipt, warehouse: warehouse} do
      box = box_fixture(%{code: "RV01", location_id: warehouse.id})
      line = line_for(receipt, 1)

      assert {:ok, counted} =
               Receiving.update_line(line, %{counted_quantity: "287", box_id: box.id})

      assert Decimal.equal?(counted.counted_quantity, Decimal.new(287))
      assert counted.box_id == box.id
      assert Decimal.equal?(ReceiptLine.divergence(counted), Decimal.new(-13))
      assert ReceiptLine.diverges?(counted)
    end

    test "a count that matches the invoice is not a divergence", %{receipt: receipt} do
      {:ok, counted} = Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "300"})

      refute ReceiptLine.diverges?(counted)
    end

    test "counting zero is not the same as not counting", %{receipt: receipt} do
      {:ok, counted} = Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "0"})

      assert Decimal.equal?(counted.counted_quantity, Decimal.new(0))
      assert ReceiptLine.diverges?(counted)

      uncounted = line_for(receipt, 2)
      assert uncounted.counted_quantity == nil
      refute ReceiptLine.diverges?(uncounted)
    end

    test "rejects a negative count", %{receipt: receipt} do
      assert {:error, changeset} =
               Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "-5"})

      assert "must be greater than or equal to 0" in errors_on(changeset).counted_quantity
    end
  end

  describe "complete_receipt/2" do
    setup %{invoice: invoice, warehouse: warehouse} do
      posted = post!(invoice, warehouse)
      {:ok, receipt} = Receiving.start_receipt(posted, %{location_id: warehouse.id})
      box = box_fixture(%{code: "RV01", location_id: warehouse.id})

      %{receipt: receipt, posted: posted, box: box}
    end

    test "posts the divergence as an adjustment with a reason", %{
      receipt: receipt,
      warehouse: warehouse
    } do
      line = line_for(receipt, 1)
      {:ok, _} = Receiving.update_line(line, %{counted_quantity: "287"})

      assert {:ok, %{corrections: correction}} =
               Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      assert correction.type == "adjustment"
      assert correction.reason_code == "count_correction"
      assert [entry] = correction.entries
      assert Decimal.equal?(entry.quantity, Decimal.new(-13))

      product_id = line.invoice_item.product_id

      assert Decimal.equal?(
               Inventory.balance(product_id: product_id, location_id: warehouse.id),
               Decimal.new(287)
             )
    end

    test "moves the counted goods into their box and verifies it", %{
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, _} = Receiving.update_line(line, %{counted_quantity: "300", box_id: box.id})

      assert {:ok, %{boxing: transfer}} =
               Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      assert transfer.type == "transfer"

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(300))

      # The balance is now verified rather than presumed.
      assert Repo.reload!(box).last_verified_at
    end

    test "a short delivery ends with the counted amount inside the box", %{
      receipt: receipt,
      box: box,
      warehouse: warehouse
    } do
      line = line_for(receipt, 1)
      {:ok, _} = Receiving.update_line(line, %{counted_quantity: "287", box_id: box.id})

      {:ok, _} =
        Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      product_id = line.invoice_item.product_id

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(287))
      # Nothing left floating outside a box for this line.
      assert Decimal.equal?(
               Inventory.balance(
                 product_id: product_id,
                 location_id: warehouse.id,
                 box_id: nil
               ),
               Decimal.new(0)
             )
    end

    test "leaves uncounted lines exactly as the invoice booked them", %{
      receipt: receipt,
      warehouse: warehouse
    } do
      {:ok, _} = Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "287"})

      {:ok, %{receipt: completed}} =
        Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      untouched = line_for(completed, 3)
      assert untouched.counted_quantity == nil

      # Item 3 is 100 nebulizers the invoice promised and nobody counted.
      assert Decimal.equal?(
               Inventory.balance(
                 product_id: untouched.invoice_item.product_id,
                 location_id: warehouse.id
               ),
               Decimal.new(100)
             )
    end

    test "records nothing in the ledger when the count agrees with the invoice", %{
      receipt: receipt
    } do
      {:ok, _} = Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "300"})

      assert {:ok, result} =
               Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      assert result.corrections == nil
      assert result.boxing == nil
      assert result.receipt.status == "completed"
      assert result.receipt.completed_at
    end

    test "refuses to complete twice", %{receipt: receipt} do
      {:ok, %{receipt: completed}} =
        Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      assert {:error, :receipt_not_open} =
               Receiving.complete_receipt(completed, user_id: actor_id())
    end

    test "a second round can be opened to recount", %{
      receipt: receipt,
      posted: posted,
      warehouse: warehouse
    } do
      {:ok, _} = Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "287"})

      {:ok, _} =
        Receiving.complete_receipt(Receiving.get_receipt!(receipt.id), user_id: actor_id())

      assert {:ok, second} = Receiving.start_receipt(posted, %{location_id: warehouse.id})
      assert second.round == 2

      # The second round measures against the invoice, not against the
      # corrected balance: the conference is always about the promise.
      assert Decimal.equal?(line_for(second, 1).expected_quantity, Decimal.new(300))

      {:ok, _} = Receiving.update_line(line_for(second, 1), %{counted_quantity: "300"})
      {:ok, %{corrections: correction}} = Receiving.complete_receipt(second, user_id: actor_id())

      assert [entry] = correction.entries
      assert Decimal.equal?(entry.quantity, Decimal.new(13))
      assert length(Receiving.list_receipts(posted)) == 2
    end
  end

  describe "divergences/1" do
    setup %{invoice: invoice, warehouse: warehouse} do
      posted = post!(invoice, warehouse)
      {:ok, receipt} = Receiving.start_receipt(posted, %{location_id: warehouse.id})
      %{receipt: receipt}
    end

    test "reports what to tell the supplier", %{receipt: receipt} do
      {:ok, _} = Receiving.update_line(line_for(receipt, 1), %{counted_quantity: "287"})
      {:ok, _} = Receiving.update_line(line_for(receipt, 2), %{counted_quantity: "50"})

      receipt = Receiving.get_receipt!(receipt.id)

      assert [divergence] = Receiving.divergences(receipt)
      assert divergence.description =~ "ELETRODO"
      assert Decimal.equal?(divergence.expected, Decimal.new(300))
      assert Decimal.equal?(divergence.counted, Decimal.new(287))
      assert Decimal.equal?(divergence.difference, Decimal.new(-13))

      assert length(Receiving.uncounted_lines(receipt)) == 2
    end
  end
end
