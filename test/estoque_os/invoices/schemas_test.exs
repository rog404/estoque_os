defmodule EstoqueOS.Invoices.SchemasTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Invoices.{Invoice, InvoiceEvent, InvoiceItem}

  @access_key "35260411222333000424550010009770981447856989"

  defp invoice_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      access_key: @access_key,
      number: "977098",
      series: "1",
      issued_on: ~D[2026-04-23],
      total: Decimal.new("1979.30"),
      raw_xml: "<nfeProc/>",
      supplier_id: supplier_fixture().id
    })
  end

  describe "invoice" do
    test "the same access key cannot be imported twice" do
      assert {:ok, _} = %Invoice{} |> Invoice.changeset(invoice_attrs()) |> Repo.insert()

      assert {:error, changeset} =
               %Invoice{}
               |> Invoice.changeset(invoice_attrs(%{supplier_id: supplier_fixture().id}))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).access_key
    end

    test "rejects an access key that is not 44 digits" do
      changeset = Invoice.changeset(%Invoice{}, invoice_attrs(%{access_key: "123"}))

      refute changeset.valid?
      assert "has invalid format" in errors_on(changeset).access_key
    end

    test "rejects an unknown status" do
      changeset = Invoice.changeset(%Invoice{}, invoice_attrs(%{status: "whatever"}))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "casts its items" do
      attrs =
        invoice_attrs(%{
          items: [
            %{
              item_number: 1,
              description: "BUPIVACAINA S/V 0.5% 25 FRASCO AMPOLA 20ML",
              commercial_unit: "CX",
              commercial_quantity: Decimal.new(2),
              commercial_unit_value: Decimal.new("130.50"),
              lot_number: "25071596",
              expires_on: ~D[2027-07-31],
              lot_source: "rastro"
            }
          ]
        })

      assert {:ok, invoice} = %Invoice{} |> Invoice.changeset(attrs) |> Repo.insert()
      assert [item] = Repo.preload(invoice, :items).items
      assert item.lot_source == "rastro"
      assert Decimal.equal?(item.commercial_unit_value, Decimal.new("130.50"))
    end
  end

  describe "invoice item" do
    test "rejects an unknown lot source" do
      changeset =
        InvoiceItem.changeset(%InvoiceItem{}, %{
          item_number: 1,
          description: "X",
          commercial_unit: "CX",
          commercial_quantity: Decimal.new(1),
          commercial_unit_value: Decimal.new(1),
          lot_source: "guessed"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).lot_source
    end

    test "rejects a non-positive quantity or conversion factor" do
      changeset =
        InvoiceItem.changeset(%InvoiceItem{}, %{
          item_number: 1,
          description: "X",
          commercial_unit: "CX",
          commercial_quantity: Decimal.new(0),
          commercial_unit_value: Decimal.new(1),
          conversion_factor: Decimal.new(0)
        })

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).commercial_quantity
      assert "must be greater than 0" in errors_on(changeset).conversion_factor
    end
  end

  describe "invoice event" do
    test "attaches a CC-e to the invoice" do
      {:ok, invoice} = %Invoice{} |> Invoice.changeset(invoice_attrs()) |> Repo.insert()

      assert {:ok, event} =
               %InvoiceEvent{}
               |> InvoiceEvent.changeset(%{
                 invoice_id: invoice.id,
                 kind: "cce",
                 sequence: 1,
                 description: "Correção de dados",
                 raw_xml: "<procEventoNFe/>"
               })
               |> Repo.insert()

      assert event.kind == "cce"
      assert [^event] = Repo.preload(invoice, :events).events
    end

    test "the same event sequence cannot repeat for an invoice" do
      {:ok, invoice} = %Invoice{} |> Invoice.changeset(invoice_attrs()) |> Repo.insert()
      attrs = %{invoice_id: invoice.id, kind: "cce", sequence: 1, raw_xml: "<x/>"}

      assert {:ok, _} = %InvoiceEvent{} |> InvoiceEvent.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %InvoiceEvent{} |> InvoiceEvent.changeset(attrs) |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).invoice_id
    end
  end
end
