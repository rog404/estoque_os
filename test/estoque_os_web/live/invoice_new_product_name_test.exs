defmodule EstoqueOSWeb.InvoiceNewProductNameTest do
  @moduledoc """
  A catalog name outlives the invoice that introduced it. The screen used to
  create the product straight from the supplier's description, which arrives
  with the shipment's lot, quantity and dates glued on and often truncated
  mid-word — so the catalog inherited that text permanently.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.{Invoices, Repo}

  setup :register_and_log_in_operator

  @sample "priv/samples/35260411222333000424550010009770981447856989-nfe.xml"

  defp imported_invoice(%{user: user}) do
    xml = File.read!(@sample)
    {:ok, invoice} = Invoices.import_document(xml, user_id: user.id)
    %{invoice: invoice}
  end

  defp unmatched_item(invoice) do
    Enum.find(invoice.items, &is_nil(&1.product_id))
  end

  # The name field is no longer rendered on every unresolved line — it belongs
  # to a line that is actually about to become a new product, and appears when
  # the operator says so. Every test here is about that field, so every one of
  # them has to say it first.
  defp choose_to_create(view, item) do
    # And the list it is offered in belongs to the search field, so it has to be
    # opened before anything in it can be clicked.
    view |> element("#search-#{item.id} input[name=query]") |> render_focus()

    view
    |> element("#matches-#{item.id} button[phx-click=choose_new]")
    |> render_click()

    view
  end

  describe "creating a product from an invoice line" do
    setup :imported_invoice

    test "offers the cleaned-up name in an editable field", %{conn: conn, invoice: invoice} do
      item = unmatched_item(invoice)

      {:ok, view, html} = live(conn, ~p"/invoices/#{invoice.id}")
      choose_to_create(view, item)

      # The supplier's raw wording stays visible — it is what the invoice says,
      # and the operator compares against it. What must not carry the shipment
      # tail is the name being proposed for the catalog.
      assert html =~ "Fornecedor: 4219"

      value =
        view
        |> element("#resolve-#{item.id} input[name=new_product_name]")
        |> render()

      assert value =~ "HYPOFARMA"
      refute value =~ "Fornecedor"
      refute value =~ "Lote:"
    end

    test "creates the product under the name the operator typed", %{
      conn: conn,
      invoice: invoice
    } do
      item = unmatched_item(invoice)
      refute is_nil(item), "the sample invoice should have an unmatched line"

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")
      choose_to_create(view, item)

      view
      |> form("#resolve-#{item.id}", %{
        "product_id" => "__new__",
        "new_product_name" => "Bupivacaína 0,5% 20ml",
        "conversion_factor" => "1"
      })
      |> render_submit()

      assert Repo.exists?(from p in Product, where: p.name == "Bupivacaína 0,5% 20ml")
      refute Repo.exists?(from p in Product, where: like(p.name, "%Fornecedor:%"))
    end

    test "falls back to the suggestion when the field is cleared", %{
      conn: conn,
      invoice: invoice
    } do
      item = unmatched_item(invoice)

      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")
      choose_to_create(view, item)

      view
      |> form("#resolve-#{item.id}", %{
        "product_id" => "__new__",
        "new_product_name" => "   ",
        "conversion_factor" => "1"
      })
      |> render_submit()

      # Something sane was created, and it is not the raw description.
      refute Repo.exists?(from p in Product, where: like(p.name, "%Fornecedor:%"))
      assert Repo.exists?(from p in Product, where: like(p.name, "%HYPOFARMA%"))
    end
  end
end
