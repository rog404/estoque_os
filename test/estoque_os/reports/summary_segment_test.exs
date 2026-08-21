defmodule EstoqueOS.Reports.SummarySegmentTest do
  @moduledoc """
  The headline numbers, once per stock.

  A note pending confirmation is a job for whoever owns the goods in it, and
  the marketing overview raising a number about a delivery of gauze is the same
  wrong answer as showing them the gauze.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Invoices.Invoice
  alias EstoqueOS.Reports

  setup do
    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    shirt = product_fixture(%{name: "Camiseta Operação Sorriso", segment: "marketing"})

    pending_invoice(gauze, "5001")

    %{gauze: gauze, shirt: shirt}
  end

  defp pending_invoice(product, number) do
    supplier = supplier_fixture()

    {:ok, invoice} =
      %Invoice{}
      |> Invoice.changeset(%{
        access_key: String.pad_leading(number, 44, "3"),
        number: number,
        issued_on: ~D[2026-04-23],
        raw_xml: "<nfeProc/>",
        supplier_id: supplier.id,
        items: [
          %{
            item_number: 1,
            description: product.name,
            product_id: product.id,
            commercial_unit: "UN",
            commercial_quantity: Decimal.new(10),
            commercial_unit_value: Decimal.new("10.00"),
            total_value: Decimal.new("100.00")
          }
        ]
      })
      |> Repo.insert()

    invoice
  end

  test "the whole operation counts every note waiting" do
    assert Reports.summary().invoices_pending == 1
  end

  test "a stock counts only the notes that carry its goods", %{shirt: shirt} do
    assert Reports.summary(segment: "medical").invoices_pending == 1
    assert Reports.summary(segment: "marketing").invoices_pending == 0

    pending_invoice(shirt, "5002")

    assert Reports.summary(segment: "marketing").invoices_pending == 1
    assert Reports.summary(segment: "medical").invoices_pending == 1
    assert Reports.summary().invoices_pending == 2
  end

  # An item the importer could not match to a product yet has no segment to be
  # counted under. It stays in the whole-operation number, which is the one the
  # person who resolves it is reading.
  test "an item without a product yet belongs to no stock", %{gauze: gauze} do
    {:ok, _} =
      %Invoice{}
      |> Invoice.changeset(%{
        access_key: String.pad_leading("5003", 44, "3"),
        number: "5003",
        issued_on: ~D[2026-04-23],
        raw_xml: "<nfeProc/>",
        supplier_id: supplier_fixture().id,
        items: [
          %{
            item_number: 1,
            description: gauze.name,
            commercial_unit: "UN",
            commercial_quantity: Decimal.new(10),
            commercial_unit_value: Decimal.new("10.00"),
            total_value: Decimal.new("100.00")
          }
        ]
      })
      |> Repo.insert()

    assert Reports.summary().invoices_pending == 2
    assert Reports.summary(segment: "medical").invoices_pending == 1
    assert Reports.summary(segment: "marketing").invoices_pending == 0
  end
end
