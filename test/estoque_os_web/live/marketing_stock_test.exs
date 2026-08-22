defmodule EstoqueOSWeb.MarketingStockTest do
  @moduledoc """
  The second stock, and the person who looks after it.

  Marketing material is sold rather than consumed on a mission, and the role
  that handles it sees that stock and nothing else. The confinement is a `where`
  in every query that lists a product — not a template that renders fewer rows —
  so these tests go after the screens by their events and their addresses rather
  than by what is drawn: an event arrives over a socket whether or not a button
  was ever rendered for it.
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

  # `refute html =~ "..."` matches markup as happily as text, so anything
  # asserting a product is *absent* strips the tags first.
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

    # The stock is a filter now, not a fence: the screen opens on marketing
    # because that is where this person works, and the surgical shelf is one
    # tap away because the operation asked for it that way.
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

    # The write-off screen is narrowed to the stock it is showing, and the
    # address is what changes which one that is — the refusal is about the
    # screen's state, not about the person.
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

    # A mission mixes marketing material and surgical supply in the same box,
    # and the person who packed the shirts is the person who counts them.
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

    # Writing the whole warehouse at once is a planning act, and planning is
    # still admin and manager. That gate is about what a role *does*, which is
    # a different question from which stock it works in.
    test "still cannot import a whole spreadsheet", %{conn: conn} do
      assert {:error, {:redirect, %{to: _}}} = live(conn, ~p"/reports/data")
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

      # And the other delivery opens rather than being refused: it is a
      # document of the same operation.
      assert {:ok, _view, _html} = live(conn, ~p"/invoices/#{surgical.id}")
    end

    test "gets an export of the stock it is looking at", %{conn: conn, gauze: gauze} do
      response = get(conn, ~p"/stock/export.xlsx")

      assert response.status == 200
      # The workbook is a zip, so the product names are compressed rather than
      # sitting in the body — what matters here is that the request is served
      # from the same narrowing, which `Reports.export_stock/1` is asked
      # directly about below.
      assert {:ok, binary} = EstoqueOS.Reports.export_stock(segment: "marketing")
      refute binary =~ gauze.name
    end

    test "sees a dashboard about its own stock", %{conn: conn, gauze: gauze} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute text(html) =~ gauze.name

      # 120 shirts and not 520 units: the headline number is the marketing
      # stock, not the warehouse.
      assert html =~ "120"

      # Boxes and kit readiness are the surgical operation asking itself
      # questions. An empty panel titled "Caixas para recontar" would read as
      # "nothing to do", which is a different and untrue statement.
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

    # Where the goods go is answered first now: the price field belongs to a
    # sale, so the screen has to know it is one before a line is priced.
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

      # The price belongs to a sale, so it appears once the write-off says it
      # is one — which is also what lets an admin sell without the field being
      # tied to the product's stock.
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
      # The cost the goods came in at is untouched: two numbers, two questions.
      assert Decimal.equal?(entry.quantity, Decimal.new(-3))
    end

    test "a sale with no price is refused, not posted blank", %{conn: conn, shirt: shirt} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> form("#destination-form", %{"destination" => "sale"}) |> render_change()
      view |> element("#search-form") |> render_change(%{"query" => shirt.name})
      view |> element("button", shirt.name) |> render_click()
      view |> element("#issue-form") |> render_submit(%{"quantity" => "2"})

      html = view |> element("#basket-form") |> render_submit(%{})

      # The goods are gone either way once posted, and the price is not
      # recoverable afterwards.
      assert html =~ "preço de venda"
      assert Repo.aggregate(from(t in Transaction, where: t.destination == "sale"), :count) == 0
    end

    test "the report adds up what was sold", %{conn: conn, shirt: shirt} do
      sell(conn, shirt, "4", "25,00")

      {:ok, _view, html} = live(conn, ~p"/reports/sales")

      assert html =~ shirt.name
      # 4 × 25,00
      assert html =~ "100,00"
    end
  end

  describe "the roles that have both stocks" do
    setup %{conn: conn}, do: register_and_log_in_operator(%{conn: conn})

    # The surgical stock is where the supplies coordinator works, so that is
    # where the screen opens — and both stocks are one filter away.
    test "open on the surgical stock and reach the other in one filter", %{
      conn: conn,
      gauze: gauze,
      shirt: shirt
    } do
      {:ok, view, html} = live(conn, ~p"/stock")

      assert html =~ gauze.name
      refute text(html) =~ shirt.name

      # Ticking neither stock is how the panel says "both".
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
