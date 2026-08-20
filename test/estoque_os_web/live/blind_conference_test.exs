defmodule EstoqueOSWeb.BlindConferenceTest do
  @moduledoc """
  A conference is a count, and a count that is shown its own answer measures
  nothing.

  `AuditLive.Count` was built on that rule and says so in its moduledoc. The
  receiving conference contradicted it for a while: it rendered "A nota diz"
  and a signed difference to whoever opened the screen, including the operator
  standing in front of the pallet. These tests hold the two halves apart — the
  operator counts, the manager reads what the count found.
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
    # Posting the invoice needs a role that may see money. The conn it hands
    # back is thrown away on purpose: each `describe` signs in as the role it is
    # about, and inheriting a manager session here would hide exactly the leak
    # these tests exist to catch.
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

  # The page with the markup taken off: what a person standing at the pallet
  # actually reads. `<script>` goes too — the theme bootstrap in the root layout
  # is a wall of text nobody sees.
  defp visible_text(html) do
    html
    |> String.replace(~r{<script.*?</script>}s, " ")
    |> String.replace(~r{<[^>]*>}s, " ")
  end

  # A count that disagrees with the invoice is not believed until it has been
  # made `Receiving.counts_required/0` times — see `Receiving.record_count/2`.
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

      # The line is there to be counted...
      assert html =~ "ELETRODO ECG ADULTO PT/50 POLYMED"
      assert html =~ "Contado"

      # ...but nothing on the page says how many the supplier promised.
      refute html =~ "A nota diz"
      refute html =~ "Divergências em relação à nota"

      # Scoped to the lines panel, not the whole page: the topbar shows the
      # logged-in operator's email, which is `"user#{System.unique_integer()}"`
      # in tests and occasionally contains "300" by chance, which made this
      # assertion flaky on a substring it never meant to check.
      lines_html = view |> element("#receipt-lines") |> render()

      # Read as the operator reads it, with the markup gone: "300" lives in
      # `border-base-300` on half the elements on the page and matching that
      # would pass this test forever.
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

      # Visible text only. A row carries `id="line-13"` whenever the line's id
      # happens to be 13, and matching that made this test pass on luck.
      refute visible_text(html) =~ "-13"
    end

    # The rule Rogerio asked for reveals one thing by design — that this line
    # disagrees — and must reveal nothing else. "A nota diz 300" next to "conte
    # de novo" would hand the operator the number to write down, which is the
    # whole failure the blind sheet exists to prevent.
    test "is asked to count again without being told the number to reach", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = hd(receipt.lines)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      text = visible_text(html)

      assert text =~ "Conte este item de novo"
      assert text =~ "contagem 2 de 3"

      # Neither the invoice's number nor the distance to it.
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
