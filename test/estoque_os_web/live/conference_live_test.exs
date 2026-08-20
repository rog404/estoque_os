defmodule EstoqueOSWeb.ConferenceLiveTest do
  @moduledoc """
  The way in.

  A conference used to be reachable only from the invoice screen, which sits
  behind the money gate — so the logistics operator, whose job this is, had no
  way to find the work. This screen is the door, and it has to stay free of
  amounts or it cannot live in Operação at all.
  """

  # Not async: imports the same real invoice as the other invoice suites.
  use EstoqueOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Invoices, Receiving}

  @samples EstoqueOS.Samples.dir()
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"

  setup %{conn: conn} do
    context = register_and_log_in_as(%{conn: conn}, "manager")
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    {:ok, invoice} =
      @samples |> Path.join(@atlantica) |> File.read!() |> Invoices.import_document()

    Enum.each(invoice.items, fn item ->
      product = product_fixture(%{name: "Produto #{item.item_number}"})

      {:ok, _} =
        Invoices.resolve_item(item, %{
          product_id: product.id,
          conversion_factor: Decimal.to_string(item.conversion_factor)
        })
    end)

    {:ok, %{invoice: posted}} =
      invoice.id
      |> Invoices.get_invoice!()
      |> Invoices.post_invoice(%{location_id: warehouse.id, user_id: actor_id()})

    Map.merge(context, %{warehouse: warehouse, invoice: posted})
  end

  describe "as the logistics operator" do
    setup :register_and_log_in_logistics

    test "the posted invoice is waiting to be counted", %{conn: conn, invoice: invoice} do
      {:ok, _view, html} = live(conn, ~p"/conferences")

      assert html =~ "Conferência"
      assert html =~ invoice.supplier.legal_name
      assert html =~ "NF #{invoice.number}"
      assert html =~ "não iniciada"
    end

    test "starting a round lands on the counting screen", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, ~p"/conferences")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("button[phx-value-invoice='#{invoice.id}']")
               |> render_click()

      assert to =~ ~r"/receipts/\d+"
    end

    test "an open round shows how far it got and offers to continue", %{
      conn: conn,
      invoice: invoice,
      warehouse: warehouse
    } do
      {:ok, receipt} =
        Receiving.start_receipt(invoice, %{location_id: warehouse.id, user_id: actor_id()})

      {:ok, _} = Receiving.update_line(hd(receipt.lines), %{counted_quantity: "10"})

      {:ok, _view, html} = live(conn, ~p"/conferences")

      assert html =~ "1 de 4"
      assert html =~ "Continuar contagem"
    end

    # The whole reason this screen can sit in Operação.
    test "no amount reaches the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/conferences")

      refute html =~ "R$"
    end
  end

  test "a conferred delivery drops off the list", %{
    conn: conn,
    invoice: invoice,
    warehouse: warehouse
  } do
    {:ok, receipt} =
      Receiving.start_receipt(invoice, %{location_id: warehouse.id, user_id: actor_id()})

    {:ok, _} = Receiving.complete_receipt(receipt, user_id: actor_id())

    {:ok, _view, html} = live(conn, ~p"/conferences")

    refute html =~ invoice.supplier.legal_name
    assert html =~ "Nada esperando conferência"
  end
end
