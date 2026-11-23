defmodule EstoqueOSWeb.BlindConferenceTest do
  @moduledoc """
  A count shown its own answer measures nothing: the operator counts blind, and
  the manager reads what the count found.
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
    # Posting needs a role that may see money. The returned conn is discarded so
    # each `describe` signs in as its own role; a manager session would hide the leak.
    _manager = register_and_log_in_as(%{conn: conn}, "manager")

    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "BC01", location_id: warehouse.id})

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

    {:ok, receipt} =
      Receiving.start_receipt(posted, %{location_id: warehouse.id, user_id: actor_id()})

    %{warehouse: warehouse, box: box, invoice: posted, receipt: receipt}
  end

  # Visible text only; `<script>` goes too (the theme bootstrap is invisible text).
  defp visible_text(html) do
    html
    |> String.replace(~r{<script.*?</script>}s, " ")
    |> String.replace(~r{<[^>]*>}s, " ")
  end

  # A disagreeing count is not believed until made `Receiving.counts_required/0` times.
  defp count_line(view, line, quantity, box_code) do
    Enum.reduce(1..Receiving.counts_required(), nil, fn _attempt, _acc ->
      view
      |> element("#count-#{line.id}")
      |> render_submit(%{"counted_quantity" => quantity, "box_code" => box_code})
    end)
  end

  describe "the operator doing the counting" do
    setup :register_and_log_in_logistics

    test "is never told what the invoice claimed", %{conn: conn, receipt: receipt} do
      {:ok, view, html} = live(conn, ~p"/receipts/#{receipt}")

      assert html =~ "ELETRODO ECG ADULTO PT/50 POLYMED"
      assert html =~ "Contado"

      refute html =~ "A nota diz"
      refute html =~ "Divergências em relação à nota"

      # Scope to the lines panel: the topbar's test email can contain "300" by
      # chance. Strip tags too: "300" lives in `border-base-300`.
      lines_html = view |> element("#receipt-lines") |> render()

      refute visible_text(lines_html) =~ "300"
    end

    test "a divergence they created stays invisible to them", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = hd(receipt.lines)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html = count_line(view, line, "287", box.code)

      refute html =~ "Divergências em relação à nota"

      # Visible text only: a row can carry `id="line-13"`.
      refute visible_text(html) =~ "-13"
    end

    # Reveals only that this line disagrees; the number to reach would defeat the blind sheet.
    test "is asked to count again without being told the number to reach", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = hd(receipt.lines)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      view
      |> element("#count-#{line.id}")
      |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      # Scope to the lines panel: the topbar's test email can contain "300" by
      # chance. Strip tags too: "300" lives in `border-base-300`.
      text = view |> element("#receipt-lines") |> render() |> visible_text()

      assert text =~ "Conte este item de novo"
      assert text =~ "contagem 2 de 3"

      refute text =~ "300"
      refute text =~ "-13"
    end

    test "sees whether a line is done instead of by how much it is off", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = hd(receipt.lines)
      {:ok, view, html} = live(conn, ~p"/receipts/#{receipt}")

      assert html =~ "a contar"

      html = count_line(view, line, "287", box.code)

      assert visible_text(html) =~ "contada"
    end
  end

  describe "whoever closes the conference" do
    setup :register_and_log_in_operator

    test "reads what the count found", %{conn: conn, receipt: receipt, box: box} do
      line = hd(receipt.lines)
      {:ok, view, html} = live(conn, ~p"/receipts/#{receipt}")

      assert html =~ "A nota diz"

      Enum.reduce(1..Receiving.counts_required(), nil, fn _attempt, _acc ->
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})
      end)

      html = render(view)

      assert html =~ "Divergências em relação à nota"
      assert html =~ "-13"
    end
  end
end
