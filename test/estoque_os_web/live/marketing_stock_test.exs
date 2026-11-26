defmodule EstoqueOSWeb.MarketingStockTest do
  @moduledoc """
  The second stock and its role. The confinement is a `where` in every product
  query, not a template rendering fewer rows, so these tests go by events and
  addresses: an event arrives over a socket whether or not a button was rendered.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Inventory.{Transaction, TransactionEntry}
  alias EstoqueOS.Invoices.Invoice
  alias EstoqueOS.Repo

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    shirt = product_fixture(%{name: "Camiseta Operação Sorriso", segment: "marketing"})

    stock_in(gauze, warehouse, 400)
    stock_in(shirt, warehouse, 120)

    %{warehouse: warehouse, gauze: gauze, shirt: shirt}
  end

  defp stock_in(product, location, quantity) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot_fixture(%{product_id: product.id}).id,
            location_id: location.id,
            quantity: Decimal.new(quantity)
          }
        ]
      })
  end

  # `refute html =~ ...` matches markup too, so absence checks strip the tags first.
  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  defp invoice_with(product, number) do
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
      |> EstoqueOS.Repo.insert()

    invoice
  end

  describe "the marketing role" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    test "opens on its own stock and can ask for the other", %{
      conn: conn,
      gauze: gauze,
      shirt: shirt
    } do
      {:ok, view, html} = live(conn, ~p"/stock")

      assert html =~ shirt.name
      refute text(html) =~ gauze.name

      {:ok, _view, asked} = live(conn, ~p"/stock?segment=medical")
      assert text(asked) =~ gauze.name

      filtered =
        view
        |> element("#filter-form")
        |> render_submit(%{"segment" => "medical"})

      assert text(filtered) =~ gauze.name
    end

    test "is offered the filter, already on its own stock", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ ~s(name="segment")
      assert html =~ ~s(value="marketing" checked)
    end

    # The refusal is about the screen's state (its address), not the person.
    test "searches the stock the screen is showing", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      html = view |> element("#search-form") |> render_change(%{"query" => "compressa"})
      refute text(html) =~ gauze.name

      refused = render_click(view, "pick", %{"product" => "#{gauze.id}"})
      assert refused =~ "não está neste estoque"

      {:ok, surgical, _html} = live(conn, ~p"/issue?segment=medical")
      found = surgical |> element("#search-form") |> render_change(%{"query" => "compressa"})

      assert text(found) =~ gauze.name
    end

    test "takes goods in for the stock the screen is showing", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/entry")

      html = view |> element("#search-form") |> render_change(%{"query" => "compressa"})
      refute text(html) =~ gauze.name

      {:ok, surgical, _html} = live(conn, ~p"/entry?segment=medical")
      found = surgical |> element("#search-form") |> render_change(%{"query" => "compressa"})

      assert text(found) =~ gauze.name
    end

    test "opens any product's page", %{conn: conn, gauze: gauze, shirt: shirt} do
      {:ok, _view, surgical} = live(conn, ~p"/products/#{gauze.id}")
      assert surgical =~ gauze.name

      {:ok, _view, html} = live(conn, ~p"/products/#{shirt.id}")
      assert html =~ shirt.name
    end

    # Marketing included: a mission box mixes marketing material and supplies.
    test "opens the boxes, the locations and the missions", %{conn: conn} do
      for path <- ~w(/boxes /locations /kits /missions /reports/audit) do
        assert {:ok, _view, _html} = live(conn, path),
               "#{path} was refused to the marketing role"
      end
    end

    test "opens the conference, the load-out and the return", %{conn: conn} do
      for path <- ~w(/conferences /returns /load-out) do
        assert {:ok, _view, _html} = live(conn, path),
               "#{path} was refused to the marketing role"
      end
    end

    # Writing the whole warehouse at once is a planning act (admin/manager),
    # independent of which stock the role works in.
    test "still cannot import a whole spreadsheet", %{conn: conn} do
      assert {:error, {:redirect, %{to: _}}} = live(conn, ~p"/stock/sheets")
    end

    test "opens the invoices, listing its own deliveries first", %{
      conn: conn,
      gauze: gauze,
      shirt: shirt
    } do
      surgical = invoice_with(gauze, "111111")
      theirs = invoice_with(shirt, "222222")

      {:ok, _view, html} = live(conn, ~p"/invoices")

      assert html =~ "222222"
      refute text(html) =~ "111111"

      {:ok, _view, html} = live(conn, ~p"/invoices/#{theirs.id}")
      assert html =~ shirt.name

      assert {:ok, _view, _html} = live(conn, ~p"/invoices/#{surgical.id}")
    end

    test "gets an export of the stock it is looking at", %{conn: conn, gauze: gauze} do
      response = get(conn, ~p"/stock/export.xlsx")

      assert response.status == 200
      # The workbook is a zip, so names are compressed; assert on the export function directly.
      assert {:ok, binary} = EstoqueOS.Reports.export_stock(segment: "marketing")
      refute binary =~ gauze.name
    end

    test "sees a dashboard about its own stock", %{conn: conn, gauze: gauze} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute text(html) =~ gauze.name

      # 120 shirts, not 520 units: the headline is the marketing stock.
      assert html =~ "120"

      # An empty box panel would read as "nothing to do", which is untrue.
      refute html =~ "Caixas para recontar"
      refute html =~ "Pronto para a próxima missão"
    end

    test "sees prices, because it sells what it holds", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ "Custo unitário"
    end
  end

  describe "selling" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    # The destination is chosen first: the price field only belongs to a sale.
    defp sell(conn, product, quantity, price) do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> form("#destination-form", %{"destination" => "sale"}) |> render_change()
      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      view
      |> element("#issue-form")
      |> render_submit(%{"quantity" => quantity, "sale_unit_price" => price})

      view |> element("#basket-form") |> render_submit(%{})
    end

    test "the line asks for a price, and the ledger keeps it", %{conn: conn, shirt: shirt} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> form("#destination-form", %{"destination" => "sale"}) |> render_change()
      view |> element("#search-form") |> render_change(%{"query" => shirt.name})
      html = view |> element("button", shirt.name) |> render_click()

      assert html =~ "Preço de venda"

      sell(conn, shirt, "3", "39,90")

      entries =
        Repo.all(
          from e in TransactionEntry,
            join: t in assoc(e, :transaction),
            where: t.destination == "sale"
        )

      assert [entry] = entries
      assert Decimal.equal?(entry.sale_unit_price, Decimal.new("39.90"))
      assert Decimal.equal?(entry.quantity, Decimal.new(-3))
    end

    test "a sale with no price is refused, not posted blank", %{conn: conn, shirt: shirt} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> form("#destination-form", %{"destination" => "sale"}) |> render_change()
      view |> element("#search-form") |> render_change(%{"query" => shirt.name})
      view |> element("button", shirt.name) |> render_click()
      view |> element("#issue-form") |> render_submit(%{"quantity" => "2"})

      html = view |> element("#basket-form") |> render_submit(%{})

      assert html =~ "preço de venda"
      assert Repo.aggregate(from(t in Transaction, where: t.destination == "sale"), :count) == 0
    end

    test "the report adds up what was sold", %{conn: conn, shirt: shirt} do
      sell(conn, shirt, "4", "25,00")

      {:ok, _view, html} = live(conn, ~p"/reports/sales")

      assert html =~ shirt.name
      assert html =~ "100,00"
    end
  end

  describe "the roles that have both stocks" do
    setup %{conn: conn}, do: register_and_log_in_operator(%{conn: conn})

    test "open on the surgical stock and reach the other in one filter", %{
      conn: conn,
      gauze: gauze,
      shirt: shirt
    } do
      {:ok, view, html} = live(conn, ~p"/stock")

      assert html =~ gauze.name
      refute text(html) =~ shirt.name

      both = view |> element("#filter-form") |> render_submit(%{"segment" => ""})

      assert text(both) =~ gauze.name
      assert text(both) =~ shirt.name
    end

    test "can narrow to one stock and back", %{conn: conn, gauze: gauze, shirt: shirt} do
      {:ok, view, _html} = live(conn, ~p"/stock")

      marketing =
        view
        |> element("#filter-form")
        |> render_submit(%{"segment" => "marketing"})

      assert marketing =~ shirt.name
      refute text(marketing) =~ gauze.name

      surgical =
        view
        |> element("#filter-form")
        |> render_submit(%{"segment" => "medical"})

      assert surgical =~ gauze.name
      refute text(surgical) =~ shirt.name
    end

    test "reach the marketing stock from the menu", %{conn: conn, gauze: gauze, shirt: shirt} do
      {:ok, _view, html} = live(conn, ~p"/stock?segment=marketing")

      assert html =~ shirt.name
      refute text(html) =~ gauze.name
    end

    test "file a product created from a marketing entry under marketing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entry?segment=marketing")

      render_change(element(view, "#search-form"), %{
        "query" => "Boné",
        "segment" => "marketing",
        "location_id" => "#{Locations.default_location().id}"
      })

      render_hook(view, "create_product", %{"name" => "Boné bordado", "stock_unit" => "UN"})

      assert EstoqueOS.Catalog.list_products(search: "Boné", segment: "marketing") != []
    end
  end
end
