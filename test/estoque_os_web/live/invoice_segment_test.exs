defmodule EstoqueOSWeb.InvoiceSegmentTest do
  @moduledoc """
  Which stock a delivery is for, decided when it is imported.

  This is the rule that used to be inferred from where the lines landed, and it
  cost the marketing role its first minute: a freshly imported invoice has no
  product on any line yet, so "does this invoice have a marketing item" answered
  no and the screen refused the person who had just uploaded the file.
  """

  # Not async: these suites import the same real invoice, so they would race
  # each other inserting the supplier's CNPJ into a unique index.
  use EstoqueOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EstoqueOS.Invoices

  @samples EstoqueOS.Samples.dir()
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"
  @access_key "35260455666777000181550040019851671590327796"

  defp sample(name), do: @samples |> Path.join(name) |> File.read!()

  defp upload_invoice(view) do
    view
    |> file_input("#upload-form", :xml, [
      %{name: @atlantica, content: sample(@atlantica), type: "text/xml"}
    ])
    |> render_upload(@atlantica)

    view |> element("#upload-form") |> render_submit()
  end

  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  describe "the marketing role" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    test "imports into its own stock and can open what it imported", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")

      assert {:error, {:live_redirect, %{to: to}}} = upload_invoice(view)

      invoice = Invoices.get_invoice_by_access_key(@access_key)

      assert invoice.segment == "marketing"
      assert to == "/invoices/#{invoice.id}"

      # The screen that used to say "você não tem permissão" the second after
      # the upload finished.
      {:ok, _view, html} = live(conn, to)
      assert text(html) =~ invoice.number
    end

    test "sees its own invoice on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")
      upload_invoice(view)

      {:ok, _view, html} = live(conn, ~p"/invoices")

      assert text(html) =~ Invoices.get_invoice_by_access_key(@access_key).number
    end

    # The lines have no product yet, so they belong to whoever the delivery was
    # imported for. Filtering them out left an empty invoice nobody could
    # resolve.
    test "sees the lines it still has to resolve", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")
      upload_invoice(view)

      invoice = Invoices.get_invoice_by_access_key(@access_key)
      shown = Invoices.get_invoice!(invoice.id, "marketing")

      assert length(shown.items) == length(Invoices.get_invoice!(invoice.id).items)
    end

    # The toggle exists for the coordinator who receives the other side's
    # delivery. It is not a way out of the role.
    test "cannot import into the surgical stock", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")

      render_click(view, "segment", %{"segment" => "medical"})
      upload_invoice(view)

      assert Invoices.get_invoice_by_access_key(@access_key).segment == "marketing"
    end
  end

  describe "a role that holds both stocks" do
    setup :register_and_log_in_operator

    test "imports into the surgical stock by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")
      upload_invoice(view)

      assert Invoices.get_invoice_by_access_key(@access_key).segment == "medical"
    end

    test "can send a delivery to the marketing stock", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")

      render_click(view, "segment", %{"segment" => "marketing"})
      upload_invoice(view)

      assert Invoices.get_invoice_by_access_key(@access_key).segment == "marketing"
    end
  end

  describe "an invoice imported for the marketing stock" do
    setup :register_and_log_in_operator

    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/invoices/import")
      render_click(view, "segment", %{"segment" => "marketing"})
      upload_invoice(view)

      %{invoice: Invoices.get_invoice_by_access_key(@access_key)}
    end

    # A coordinator confirming a marketing delivery must not create shirts in
    # the surgical catalog because that is where their own default points.
    test "files a product created from it under its own stock", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

      item = hd(Invoices.get_invoice!(invoice.id).items)

      view
      |> element("#item-#{item.id} form[phx-submit=resolve]")
      |> render_submit(%{"product_id" => "__new__", "conversion_factor" => "1"})

      product = EstoqueOS.Repo.get_by!(EstoqueOS.Catalog.Product, name: item.description)

      assert product.segment == "marketing"
    end
  end
end
