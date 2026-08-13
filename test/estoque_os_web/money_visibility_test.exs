defmodule EstoqueOSWeb.MoneyVisibilityTest do
  @moduledoc """
  The logistics operator is a partner outside the ONG. The spreadsheet they have
  always returned carries description, quantity and box, and never a price.

  Until four roles existed, a role said whether you could *write*; whether you
  could *see* was the same answer for everyone who could log in, so that partner
  could read every purchase price in the catalog and what each location is
  worth. These tests hold the line where it was drawn.

  They assert on rendered output rather than on assigns on purpose: hiding a
  number in markup still ships it to the browser, and "not rendered" is the only
  version of this that is true.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup %{conn: conn} do
    warehouse = EstoqueOS.Inventory.Locations.default_location() || location_fixture()
    box = box_fixture(%{location_id: warehouse.id})
    product = product_fixture(%{name: "Compressa de gaze"})
    lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2029-01-31]})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: box.id,
            quantity: Decimal.new(10),
            unit_cost: Decimal.new("13.37")
          }
        ]
      })

    %{conn: conn, product: product, warehouse: warehouse}
  end

  describe "the logistics operator" do
    setup context, do: register_and_log_in_logistics(context)

    test "sees no price on the stock screen", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ "Compressa de gaze"
      refute html =~ "13,37"
      refute html =~ "Custo unitário"
      refute html =~ "R$"
    end

    test "sees no value on the overview or the locations list", %{conn: conn} do
      {:ok, _view, home} = live(conn, ~p"/")
      refute home =~ "R$"

      {:ok, _view, locations} = live(conn, ~p"/locations")
      refute locations =~ "R$"
    end

    test "sees no price history on a product", %{conn: conn, product: product} do
      {:ok, _view, html} = live(conn, ~p"/products/#{product.id}")

      assert html =~ "Compressa de gaze"
      refute html =~ "13,37"
      refute html =~ "R$"
    end

    test "cannot open an invoice, which is a document of prices", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/invoices")
    end

    test "cannot reach the screens whose subject is money", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/invoices/import")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/issue")
    end

    test "still does the job: counting, loading out, receiving a return", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/audit")
      assert {:ok, _view, _html} = live(conn, ~p"/load-out")
      assert {:ok, _view, _html} = live(conn, ~p"/returns")
      assert {:ok, _view, _html} = live(conn, ~p"/entry")
    end

    test "downloads the count spreadsheet, trimmed rather than refused", %{conn: conn} do
      # Refusing the export is not an option — sending it back counted is their
      # job. What leaves is the sheet they have always had on paper.
      conn = get(conn, ~p"/stock/export.xlsx")

      assert conn.status == 200
      assert {:ok, rows} = EstoqueOS.Reports.StockWorkbook.import_rows(conn.resp_body)

      headers =
        conn.resp_body
        |> then(&elem(XlsxReader.open(&1, source: :binary), 1))
        |> then(&elem(XlsxReader.sheet(&1, "Estoque"), 1))
        |> List.first()

      assert "Quantidade" in headers
      assert "Caixa" in headers
      refute "Custo unitário" in headers
      refute "Total" in headers

      # And it still reads back in, which is the whole point of the round trip.
      assert Enum.any?(rows, &(&1.product == "Compressa de gaze"))
    end
  end

  describe "the auditor" do
    setup context, do: register_and_log_in_as(context, "auditor")

    test "reads every price, because that is what an audit is", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ "13,37"
      assert html =~ "Custo unitário"
    end

    test "opens an invoice", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/invoices")
    end

    test "writes nothing", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/load-out")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/audit")
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/entry")
    end
  end

  describe "the manager" do
    setup context, do: register_and_log_in_operator(context)

    test "sees the prices and does the work", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")
      assert html =~ "13,37"

      assert {:ok, _view, _html} = live(conn, ~p"/invoices/import")
      assert {:ok, _view, _html} = live(conn, ~p"/load-out")
    end
  end
end
