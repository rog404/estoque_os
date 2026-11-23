defmodule EstoqueOSWeb.ReceiptLiveTest do
  # Not async: imports the same real invoice as the other invoice suites.
  use EstoqueOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Invoices, Receiving}
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Receiving.ReceiptLine

  @samples EstoqueOS.Samples.dir()
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "RC01", location_id: warehouse.id})

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

    invoice = Invoices.get_invoice!(invoice.id)

    {:ok, %{invoice: posted}} =
      Invoices.post_invoice(invoice, %{location_id: warehouse.id, user_id: actor_id()})

    %{warehouse: warehouse, box: box, invoice: posted}
  end

  defp line_for(receipt, item_number) do
    Enum.find(receipt.lines, &(&1.invoice_item.item_number == item_number))
  end

  defp line_order(html) do
    ~r/id="line-(\d+)"/ |> Regex.scan(html) |> Enum.map(fn [_whole, id] -> id end)
  end

  # One line's form: the whole page would let another row's value satisfy the assertion.
  defp form_for_line(html, line) do
    case Regex.run(~r{<form[^>]*id="count-#{line.id}".*?</form>}s, html) do
      [form] -> form
      nil -> flunk("no count form for line #{line.id}")
    end
  end

  defp count_fields(html) do
    ~r{<input[^>]*name="counted_quantity"[^>]*>}
    |> Regex.scan(html)
    |> Enum.map(fn [field] -> field end)
  end

  defp reload_line(receipt, line) do
    Receiving.get_receipt!(receipt.id).lines |> Enum.find(&(&1.id == line.id))
  end

  # A disagreeing number is believed only after `Receiving.counts_required/0`
  # counts; an agreeing one is recorded at once, so stop as soon as it settles.
  defp count_line(view, receipt, line, quantity, box_code) do
    Enum.reduce_while(1..Receiving.counts_required(), nil, fn _attempt, _acc ->
      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => quantity, "box_code" => box_code})

      if reload_line(receipt, line).counted_quantity, do: {:halt, html}, else: {:cont, html}
    end)
  end

  test "the invoice screen offers the conference once it is posted", %{
    conn: conn,
    invoice: invoice
  } do
    {:ok, view, html} = live(conn, ~p"/invoices/#{invoice}")

    assert html =~ "Conferência de recebimento"

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("button", "Iniciar conferência") |> render_click()

    assert to =~ ~r"/receipts/\d+"
  end

  describe "conference screen" do
    setup %{invoice: invoice, warehouse: warehouse} do
      {:ok, receipt} = Receiving.start_receipt(invoice, %{location_id: warehouse.id})
      %{receipt: receipt}
    end

    test "lists every line with what the invoice promised", %{conn: conn, receipt: receipt} do
      {:ok, _view, html} = live(conn, ~p"/receipts/#{receipt}")

      assert html =~ "ELETRODO ECG ADULTO PT/50 POLYMED"
      assert html =~ "300"
      assert html =~ "4 linha(s) não contada(s)"
    end

    test "an uncounted line offers an empty field, not an em dash", %{
      conn: conn,
      receipt: receipt
    } do
      {:ok, _view, html} = live(conn, ~p"/receipts/#{receipt}")

      for field <- count_fields(html) do
        assert field =~ ~s(value="") or not (field =~ "value=")
        refute field =~ "—"
      end
    end

    # Lines must keep a stable order, or the row being typed into jumps.
    test "recording a line leaves the others where they were", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, html} = live(conn, ~p"/receipts/#{receipt}")

      before = line_order(html)

      after_saving =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})
        |> line_order()

      assert after_saving == before
    end

    # Every line is its own form with server-rendered values, so saving one
    # repaints all; unsaved drafts must survive it.
    test "recording a line keeps what was typed into the others", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      recorded = line_for(receipt, 1)
      typed = line_for(receipt, 2)

      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      view
      |> element("#count-#{typed.id}")
      |> render_change(%{"counted_quantity" => "42", "box_code" => "RC01"})

      html =
        view
        |> element("#count-#{recorded.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      form = form_for_line(html, typed)
      assert form =~ ~s(value="42")
      assert form =~ ~s(value="RC01")
    end

    # Once saved, the draft is spent: show what the database accepted.
    test "a recorded line shows the saved number, not the draft", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      view |> element("#count-#{line.id}") |> render_change(%{"counted_quantity" => "9"})

      html = count_line(view, receipt, line, "287", box.code)

      form = form_for_line(html, line)
      assert form =~ ~s(value="287")
      refute form =~ ~s(value="9")
    end

    # A taken-but-unbelieved count must leave the field empty, or the recount is
    # a reading of the first.
    test "a line waiting to be counted again shows an empty field", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      form = form_for_line(html, line)
      assert form =~ ~s(name="counted_quantity" value="")
      refute form =~ ~s(value="287")

      # The box stays: the goods are on that shelf whatever the count turns out to be.
      assert form =~ box.code
    end

    # Counting the second line must not take the tick off the first.
    test "every counted line keeps saying it was recorded", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      first = line_for(receipt, 1)
      second = line_for(receipt, 2)

      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      view
      |> element("#count-#{first.id}")
      |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      html =
        view
        |> element("#count-#{second.id}")
        |> render_submit(%{"counted_quantity" => "50", "box_code" => box.code})

      assert form_for_line(html, first) =~ "registrado"
      assert form_for_line(html, second) =~ "registrado"
    end

    # The tick appearing must not push the row around under the thumb.
    test "the recorded tick is present before it is earned, only invisible", %{
      conn: conn,
      receipt: receipt
    } do
      line = line_for(receipt, 1)
      {:ok, _view, html} = live(conn, ~p"/receipts/#{receipt}")

      form = form_for_line(html, line)

      # Rendered so the row height is fixed; hidden so it claims nothing yet.
      assert form =~ "registrado"
      assert form =~ "invisible"
    end

    # CX-102 typed for CX-012 would create an empty box nobody opens, holding the
    # difference forever.
    test "an unknown box code is not created until it is confirmed", %{
      conn: conn,
      receipt: receipt
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => "CX-102"})

      assert html =~ "CX-102"
      assert html =~ "Criar a caixa"

      refute Locations.get_box_by_code("CX-102")

      saved = Receiving.get_receipt!(receipt.id).lines |> Enum.find(&(&1.id == line.id))
      assert is_nil(saved.counted_quantity)
    end

    test "confirming creates the box and records the count that was waiting", %{
      conn: conn,
      receipt: receipt
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      view
      |> element("#count-#{line.id}")
      |> render_submit(%{"counted_quantity" => "287", "box_code" => "CX-102"})

      html = view |> element("#confirm-new-box") |> render_click()

      box = Locations.get_box_by_code("CX-102")
      assert box
      assert box.location_id == receipt.location_id

      refute html =~ "Criar a caixa"

      # The waiting count disagrees with the invoice, so it is taken as a first
      # count, not the answer; the box is recorded regardless.
      saved = reload_line(receipt, line)
      assert is_nil(saved.counted_quantity)
      assert [attempt] = saved.count_attempts
      assert Decimal.equal?(attempt, Decimal.new(287))
      assert saved.box_id == box.id
      assert html =~ "Conte este item de novo"
    end

    test "declining keeps the typed count so the code can be corrected", %{
      conn: conn,
      receipt: receipt
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      view
      |> element("#count-#{line.id}")
      |> render_submit(%{"counted_quantity" => "287", "box_code" => "CX-102"})

      html = view |> element("#cancel-new-box") |> render_click()

      refute Locations.get_box_by_code("CX-102")
      refute html =~ "Criar a caixa"

      # They mistyped the box, not the count; retyping a count risks rounding it.
      assert form_for_line(html, line) =~ ~s(value="287")
    end

    test "recording a short count shows the divergence", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      first =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      # One disagreeing count is more often a miscount than a loss, so the line
      # asks again, on the row rather than in a flash.
      assert first =~ "Conte este item de novo"
      assert first =~ "contagem 2 de 3"
      refute first =~ "Divergências em relação à nota"

      html = count_line(view, receipt, line, "287", box.code)

      assert html =~ "registrado"
      assert html =~ "Divergências em relação à nota"
      assert html =~ "a nota diz 300, contamos 287"
      assert html =~ "-13"
      assert html =~ "3 linha(s) não contada(s)"

      assert reload_line(receipt, line) |> ReceiptLine.diverged_after_recounts?()
    end

    test "a count that agrees with the invoice is believed the first time", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "300", "box_code" => box.code})

      refute html =~ "Conte este item de novo"
      assert Decimal.equal?(reload_line(receipt, line).counted_quantity, Decimal.new(300))
    end

    test "the trail of every count is kept, in the order they were made", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      for counted <- ~w(287 290 288) do
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => counted, "box_code" => box.code})
      end

      saved = reload_line(receipt, line)

      # The last count is the one booked.
      assert Enum.map(saved.count_attempts, &Decimal.to_string/1) == ~w(287 290 288)
      assert Decimal.equal?(saved.counted_quantity, Decimal.new(288))
    end

    test "counting a line again starts the count from nothing", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      count_line(view, receipt, line, "287", box.code)

      view
      |> element(~s(button[phx-click="count_again"][phx-value-line="#{line.id}"]))
      |> render_click()

      # A kept trail would make the next single count the third attempt, believed at once.
      assert reload_line(receipt, line).count_attempts == []

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "287", "box_code" => box.code})

      assert html =~ "Conte este item de novo"
      assert is_nil(reload_line(receipt, line).counted_quantity)
    end

    test "closing the conference writes the correction and fills the box", %{
      conn: conn,
      receipt: receipt,
      box: box,
      warehouse: warehouse
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      count_line(view, receipt, line, "287", box.code)

      html = view |> element("#complete-form") |> render_submit()

      assert html =~ "Conferência encerrada e estoque atualizado"

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(287))

      assert Decimal.equal?(
               Inventory.balance(location_id: warehouse.id, box_id: nil),
               Decimal.new(250)
             )
    end

    # Nothing reaches the ledger until the close, so this is an edit, not an adjustment.
    test "a recorded line can be counted again, from empty", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      count_line(view, receipt, line, "287", box.code)

      html =
        view
        |> element(~s(button[phx-click="count_again"][phx-value-line="#{line.id}"]))
        |> render_click()

      form = form_for_line(html, line)

      # Empty, not 287: a count that starts from the first is not a second count.
      assert form =~ ~s(name="counted_quantity" value="")

      assert form =~ box.code

      assert Receiving.get_receipt!(receipt.id).lines
             |> Enum.find(&(&1.id == line.id))
             |> Map.fetch!(:counted_quantity) == nil
    end

    test "the count-again button is reserved before it can be used", %{
      conn: conn,
      receipt: receipt
    } do
      line = line_for(receipt, 1)
      {:ok, _view, html} = live(conn, ~p"/receipts/#{receipt}")

      # Same as the recorded tick: a control appearing on save moves the next row.
      [button] =
        Regex.run(~r{<button[^>]*phx-click="count_again"[^>]*>}, form_for_line(html, line))

      assert button =~ "invisible"
      assert button =~ "disabled"
    end

    test "closing with lines uncounted names them first", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      {:ok, view, html} = live(conn, ~p"/receipts/#{receipt}")

      dialog = Regex.run(~r{<dialog[^>]*id="uncounted-warning".*?</dialog>}s, html) |> hd()

      # The products, not the number: "4 linhas" is not actionable.
      assert dialog =~ "Produto 2"
      assert dialog =~ "Produto 3"

      # Going back is the loud button; continuing is plain and never blocked.
      [{back, _}] = Regex.run(~r{btn btn-primary}, dialog, return: :index)
      [{anyway, _}] = Regex.run(~r{btn btn-ghost}, dialog, return: :index)
      assert anyway < back

      assert html =~ ~s(data-confirm-open="uncounted-warning")

      Enum.each(receipt.lines, fn each ->
        count_line(view, receipt, each, "1", box.code)
      end)

      refute render(view) =~ ~s(id="uncounted-warning")

      assert view |> element("#complete-form") |> render_submit() =~
               "Conferência encerrada"
    end

    test "a bad number is rejected with a readable message", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "-4", "box_code" => box.code})

      assert html =~ "Digite a quantidade contada como número"
    end

    # Loose stock cannot travel. The field says `required`; this is the rule
    # behind it, which a socket message cannot skip.
    test "a line cannot be recorded without a box", %{conn: conn, receipt: receipt} do
      line = line_for(receipt, 1)
      {:ok, view, _html} = live(conn, ~p"/receipts/#{receipt}")

      html =
        view
        |> element("#count-#{line.id}")
        |> render_submit(%{"counted_quantity" => "300", "box_code" => ""})

      assert html =~ "Diga em qual caixa"

      assert Receiving.get_receipt!(receipt.id).lines
             |> Enum.find(&(&1.id == line.id))
             |> Map.fetch!(:counted_quantity) == nil
    end
  end
end
