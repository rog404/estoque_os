defmodule EstoqueOS.InvoicesTest do
  # Not async: these suites import the same real invoice, so they would race
  # each other inserting the supplier's CNPJ into a unique index and deadlock.
  use EstoqueOS.DataCase, async: false

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Catalog, Inventory, Invoices}

  @samples Path.expand("../../samples", __DIR__)
  @medsul "35260411222333000424550010009770981447856989-nfe.xml"
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"
  @correction_letter "1101103526041122233300042455001000977098144785698901-cce.xml"

  defp sample(name), do: @samples |> Path.join(name) |> File.read!()

  defp import!(name) do
    {:ok, invoice} = name |> sample() |> Invoices.import_document()
    invoice
  end

  defp item(invoice, number), do: Enum.find(invoice.items, &(&1.item_number == number))

  describe "import_document/2" do
    test "creates the supplier from the invoice" do
      invoice = import!(@atlantica)

      assert invoice.supplier.cnpj == "55666777000181"
      assert invoice.supplier.legal_name =~ "CIRURGICA ATLANTICA"
    end

    test "reuses a supplier we already know" do
      supplier = supplier_fixture(%{cnpj: "55666777000181", legal_name: "Já cadastrado"})
      invoice = import!(@atlantica)

      assert invoice.supplier_id == supplier.id
      assert invoice.supplier.legal_name == "Já cadastrado"
    end

    test "stores every line with its lot data" do
      invoice = import!(@medsul)

      assert length(invoice.items) == 7
      assert item(invoice, 1).lot_number == "25071596"
      assert item(invoice, 1).expires_on == ~D[2027-07-31]
      assert item(invoice, 1).lot_source == "rastro"
    end

    test "keeps the raw XML for auditing" do
      invoice = import!(@medsul)

      assert invoice.raw_xml =~ "infNFe"
      assert invoice.status == "parsed"
    end

    test "refuses to import the same access key twice" do
      invoice = import!(@medsul)

      assert {:error, :already_imported, existing} =
               @medsul |> sample() |> Invoices.import_document()

      assert existing.id == invoice.id
    end

    test "flags every unmatched line for review" do
      invoice = import!(@atlantica)

      assert Enum.all?(invoice.items, & &1.needs_review)
      assert Enum.all?(invoice.items, &is_nil(&1.product_id))
      assert length(Invoices.unresolved_items(invoice)) == 4
    end

    test "matches a product we already know by GTIN, with its pack size" do
      product = product_fixture(%{name: "Eletrodo ECG adulto"})

      product_identifier_fixture(%{
        kind: "gtin",
        value: "07899780182401",
        product_id: product.id
      })

      invoice = import!(@atlantica)
      eletrodo = item(invoice, 1)

      assert eletrodo.product_id == product.id
      # "ELETRODO ECG ADULTO PT/50 POLYMED" — the pack size read off the line.
      assert Decimal.equal?(eletrodo.conversion_factor, Decimal.new(50))
      assert Decimal.equal?(Decimal.round(eletrodo.unit_cost, 4), Decimal.new("0.2695"))
      refute eletrodo.needs_review
    end

    test "a confirmed conversion beats the pack size guessed from the text" do
      product = product_fixture(%{name: "Eletrodo ECG adulto"})

      product_identifier_fixture(%{kind: "gtin", value: "07899780182401", product_id: product.id})

      {:ok, _} =
        Catalog.confirm_conversion(%{product_id: product.id, from_unit: "PT", factor: 25})

      invoice = import!(@atlantica)

      assert Decimal.equal?(item(invoice, 1).conversion_factor, Decimal.new(25))
    end

    test "matches by the supplier's own code when there is no GTIN match" do
      supplier = supplier_fixture(%{cnpj: "11222333000424", legal_name: "MedSul"})
      product = product_fixture(%{name: "Bupivacaína 0,5% 20ml"})

      product_identifier_fixture(%{
        kind: "supplier_code",
        value: "9120",
        product_id: product.id,
        supplier_id: supplier.id
      })

      invoice = import!(@medsul)

      assert item(invoice, 1).product_id == product.id
    end

    test "rejects a document no importer understands" do
      assert {:error, :unsupported_document} = Invoices.import_document("<html/>")
    end
  end

  describe "attach_event/1" do
    test "attaches a CC-e to its invoice" do
      invoice = import!(@medsul)

      assert {:ok, event} = @correction_letter |> sample() |> Invoices.attach_event()
      assert event.invoice_id == invoice.id
      assert event.kind == "cce"
    end

    test "refuses a CC-e for an invoice we never imported" do
      assert {:error, :invoice_not_imported} =
               @correction_letter |> sample() |> Invoices.attach_event()
    end
  end

  describe "resolve_item/3" do
    setup do
      invoice = import!(@atlantica)
      %{invoice: invoice, item: item(invoice, 1)}
    end

    test "records the product, the factor and the resulting unit cost", %{item: item} do
      product = product_fixture(%{name: "Eletrodo ECG adulto"})

      assert {:ok, resolved} =
               Invoices.resolve_item(item, %{product_id: product.id, conversion_factor: "50"})

      assert resolved.product_id == product.id
      assert Decimal.equal?(Decimal.round(resolved.unit_cost, 4), Decimal.new("0.2695"))
      refute resolved.needs_review
    end

    test "accepts a factor typed with a comma", %{item: item} do
      product = product_fixture()

      assert {:ok, resolved} =
               Invoices.resolve_item(item, %{product_id: product.id, conversion_factor: "1,5"})

      assert Decimal.equal?(resolved.conversion_factor, Decimal.new("1.5"))
    end

    test "teaches the catalog how this supplier names the product", %{item: item} do
      product = product_fixture()

      {:ok, _} = Invoices.resolve_item(item, %{product_id: product.id, conversion_factor: "50"})

      assert Catalog.get_product_by_gtin("07899780182401").id == product.id
      supplier = Catalog.get_supplier_by_cnpj("55666777000181")
      assert Catalog.get_product_by_supplier_code(supplier.id, "91538").id == product.id
      assert Catalog.get_conversion(product.id, "PT").factor |> Decimal.equal?(Decimal.new(50))
    end

    test "the next invoice from the same supplier matches on its own", %{item: item} do
      product = product_fixture()
      {:ok, _} = Invoices.resolve_item(item, %{product_id: product.id, conversion_factor: "50"})

      # Same supplier, same items, a later invoice: nothing left to resolve.
      reimported =
        sample(@atlantica)
        |> String.replace("19851671590327796", "19851671590327797")
        |> String.replace("<nNF>1985167</nNF>", "<nNF>1985168</nNF>")

      {:ok, invoice} = Invoices.import_document(reimported)

      assert item(invoice, 1).product_id == product.id
      assert Decimal.equal?(item(invoice, 1).conversion_factor, Decimal.new(50))
      refute item(invoice, 1).needs_review
    end

    test "fills in lot data the invoice never carried", %{item: item} do
      product = product_fixture()

      assert {:ok, resolved} =
               Invoices.resolve_item(item, %{
                 product_id: product.id,
                 conversion_factor: "50",
                 lot_number: "DIGITADO-1",
                 expires_on: ~D[2027-12-31],
                 lot_source: "manual"
               })

      assert resolved.lot_number == "DIGITADO-1"
      assert resolved.lot_source == "manual"
      refute resolved.needs_review
    end
  end

  describe "post_invoice/2" do
    setup do
      warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
      invoice = import!(@atlantica)

      # Resolve every line the way a human would on the confirmation screen.
      invoice =
        Enum.reduce(invoice.items, invoice, fn item, _acc ->
          product = product_fixture(%{name: "Produto #{item.item_number} #{item.description}"})

          {:ok, _} =
            Invoices.resolve_item(item, %{
              product_id: product.id,
              conversion_factor: Decimal.to_string(item.conversion_factor || Decimal.new(1))
            })

          Invoices.get_invoice!(invoice.id)
        end)

      %{invoice: invoice, warehouse: warehouse}
    end

    test "turns commercial quantities into stock units", %{
      invoice: invoice,
      warehouse: warehouse
    } do
      assert {:ok, %{transaction: transaction}} =
               Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      assert transaction.type == "purchase_in"
      assert length(transaction.entries) == 4

      eletrodo = item(Invoices.get_invoice!(invoice.id), 1)
      # 6 packs of 50 electrodes = 300 units in stock.
      assert Decimal.equal?(
               Inventory.balance(product_id: eletrodo.product_id),
               Decimal.new(300)
             )
    end

    test "snapshots the unit cost on every entry", %{invoice: invoice, warehouse: warehouse} do
      {:ok, %{transaction: transaction}} =
        Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      assert Enum.all?(transaction.entries, &(&1.unit_cost != nil))

      eletrodo_entry = Enum.min_by(transaction.entries, & &1.id)
      assert Decimal.equal?(Decimal.round(eletrodo_entry.unit_cost, 4), Decimal.new("0.2695"))
    end

    test "creates the lots the invoice describes", %{invoice: invoice, warehouse: warehouse} do
      {:ok, _} = Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      posted = Invoices.get_invoice!(invoice.id)
      eletrodo = item(posted, 1)

      lot = Repo.get_by!(EstoqueOS.Inventory.Lot, product_id: eletrodo.product_id)
      assert lot.lot_number == "114391U02"
      assert lot.expires_on == ~D[2027-03-31]
    end

    test "marks the invoice as posted and links the transaction", %{
      invoice: invoice,
      warehouse: warehouse
    } do
      {:ok, %{invoice: posted, transaction: transaction}} =
        Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      assert posted.status == "posted"
      assert posted.posted_at
      assert transaction.invoice_id == invoice.id
    end

    test "refuses to post twice", %{invoice: invoice, warehouse: warehouse} do
      {:ok, %{invoice: posted}} =
        Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      assert {:error, :already_posted} =
               Invoices.post_invoice(posted, %{location_id: warehouse.id, user_id: actor_id()})
    end

    test "refuses to post while a line is unresolved", %{warehouse: warehouse} do
      invoice = import!(@medsul)

      assert {:error, {:unresolved_items, items}} =
               Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      assert length(items) == 7
    end
  end

  describe "suspicious_items/1" do
    test "catches the classic total-versus-unit swap" do
      warehouse = location_fixture(%{kind: "warehouse"})
      product = product_fixture(%{name: "Eletrodo ECG adulto"})
      lot = lot_fixture(%{product_id: product.id})

      # History says this item costs cents per unit.
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              quantity: Decimal.new(100),
              unit_cost: Decimal.new("0.2695")
            }
          ]
        })

      product_identifier_fixture(%{kind: "gtin", value: "07899780182401", product_id: product.id})

      invoice = import!(@atlantica)
      eletrodo = item(invoice, 1)

      # Someone confirms "1 PT = 1 unit": the pack price becomes the unit price.
      {:ok, _} =
        Invoices.resolve_item(eletrodo, %{product_id: product.id, conversion_factor: "1"})

      assert [suspicious] = invoice.id |> Invoices.get_invoice!() |> Invoices.suspicious_items()
      assert suspicious.item.id == eletrodo.id
      assert Decimal.compare(suspicious.factor, Decimal.new(10)) != :lt
    end

    test "says nothing when the price is in line with history" do
      product = product_fixture(%{name: "Eletrodo ECG adulto"})
      product_identifier_fixture(%{kind: "gtin", value: "07899780182401", product_id: product.id})

      invoice = import!(@atlantica)

      assert Invoices.suspicious_items(invoice) == []
    end
  end
end
