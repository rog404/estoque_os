defmodule EstoqueOSWeb.InvoiceLiveTest do
  # Not async: these suites import the same real invoice, so they would race
  # each other inserting the supplier's CNPJ into a unique index and deadlock.
  use EstoqueOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Invoices}

  @samples EstoqueOS.Samples.dir()
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"

  setup :register_and_log_in_operator

  defp sample(name), do: @samples |> Path.join(name) |> File.read!()

  defp upload_invoice(view, name) do
    view
    |> file_input("#upload-form", :xml, [
      %{name: name, content: sample(name), type: "text/xml"}
    ])
    |> render_upload(name)

    view |> element("#upload-form") |> render_submit()
  end

  describe "import" do
    test "uploading an XML creates the invoice and moves on to confirmation", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/invoices/import")
      assert html =~ "Importar nota fiscal"

      assert {:error, {:live_redirect, %{to: to}}} = upload_invoice(view, @atlantica)

      invoice = Invoices.get_invoice_by_access_key("35260455666777000181550040019851671590327796")
      assert to == "/invoices/#{invoice.id}"
    end

    test "a file that is not an NF-e is refused with a readable message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")

      view
      |> file_input("#upload-form", :xml, [
        %{name: "qualquer.xml", content: "<html/>", type: "text/xml"}
      ])
      |> render_upload("qualquer.xml")

      assert view |> element("#upload-form") |> render_submit() =~
               "não é um XML de NF-e"
    end
  end

  describe "confirmation screen" do
    setup do
      location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
      {:ok, invoice} = @atlantica |> sample() |> Invoices.import_document()
      %{invoice: invoice}
    end

    test "lists every line with what the parser understood", %{conn: conn, invoice: invoice} do
      {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "ELETRODO ECG ADULTO PT/50 POLYMED"
      assert html =~ "114391U02"
      assert html =~ "CIRURGICA ATLANTICA"
      # Four lines still waiting for a product.
      assert html =~ "4 item(ns) pendente(s)"
    end

    test "posting is blocked while items are unresolved", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice}")

      assert view |> element("button[disabled]") |> has_element?()
      assert render(view) =~ "Confirme todos os itens antes de lançar"
    end

    test "confirming a line records the product and shows the unit price", %{
      conn: conn,
      invoice: invoice
    } do
      product = product_fixture(%{name: "Eletrodo ECG adulto"})
      item = Enum.find(invoice.items, &(&1.item_number == 1))

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice}")

      html =
        view
        |> element("#item-#{item.id} form[phx-submit=resolve]")
        |> render_submit(%{"product_id" => product.id, "conversion_factor" => "50"})

      assert html =~ "Item confirmado"
      # 13,475 / 50 = 0,2695 per electrode.
      assert html =~ "0,2695"
      assert html =~ "3 item(ns) pendente(s)"
    end

    test "an operator can create the product straight from the supplier's wording", %{
      conn: conn,
      invoice: invoice
    } do
      item = Enum.find(invoice.items, &(&1.item_number == 2))
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice}")

      view
      |> element("#item-#{item.id} form[phx-submit=resolve]")
      |> render_submit(%{"product_id" => "__new__", "conversion_factor" => "1"})

      assert EstoqueOS.Catalog.get_product_by_gtin("8904450902414")
    end

    test "confirming without a product asks for one", %{conn: conn, invoice: invoice} do
      item = Enum.find(invoice.items, &(&1.item_number == 1))
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice}")

      html =
        view
        |> element("#item-#{item.id} form[phx-submit=resolve]")
        |> render_submit(%{"product_id" => "", "conversion_factor" => "50"})

      assert html =~ "Selecione um produto"
    end

    test "the whole flow ends with stock in the warehouse", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice}")

      for item <- invoice.items do
        view
        |> element("#item-#{item.id} form[phx-submit=resolve]")
        |> render_submit(%{
          "product_id" => "__new__",
          "conversion_factor" => Decimal.to_string(item.conversion_factor)
        })
      end

      warehouse = EstoqueOS.Inventory.Locations.default_location()

      html =
        view
        |> element("form[phx-submit=post]")
        |> render_submit(%{"location_id" => warehouse.id})

      # The end of the flow states what entered stock, instead of a corner toast.
      assert html =~ "está no estoque"
      assert html =~ "4 item(ns)"
      assert html =~ "550 unidade(s)"
      assert html =~ "Estoque Principal"

      # 6 packs of 50 electrodes + 50 plates + 100 + 100 nebulizers.
      assert Decimal.equal?(
               Inventory.balance(location_id: warehouse.id),
               Decimal.new(550)
             )

      assert Invoices.get_invoice!(invoice.id).status == "posted"

      # And the screen stops being a stack of cards. There are no decisions left
      # on a posted invoice, so a card per line is a page you scroll to read
      # four columns; what it is now is a record, read across.
      assert html =~ "O que foi lançado"
      refute html =~ ~s(name="conversion_factor")
      refute html =~ "Buscar no catálogo"
    end
  end

  describe "index" do
    test "shows imported invoices", %{conn: conn} do
      {:ok, invoice} = @atlantica |> sample() |> Invoices.import_document()

      {:ok, _view, html} = live(conn, ~p"/invoices")

      assert html =~ invoice.number
      assert html =~ "Pendente de confirmação"
    end

    test "says so when there is nothing yet", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/invoices")

      assert html =~ "Nenhuma nota fiscal importada"
    end
  end
end
