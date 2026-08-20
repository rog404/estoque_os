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

  # The rows as rendered, in the order they were rendered in.
  defp line_order(html) do
    ~r/id="line-(\d+)"/ |> Regex.scan(html) |> Enum.map(fn [_whole, id] -> id end)
  end

  # One line's form, alone. Asserting against the whole page would let a value
  # belonging to another row satisfy the assertion.
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

  # Counting a line the way the screen now asks for it: a number that disagrees
  # with the invoice is not believed until it has been counted
  # `Receiving.counts_required/0` times. A number that agrees is recorded on the
  # first submit, so this stops as soon as the line is settled rather than
  # submitting a fixed three times into a locked form.
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

    # The operator typed into row four and watched it move: the lines came back
    # from Postgres in whatever order the plan produced.
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

    # The operator counts six boxes onto one screen, records the first, and the
    # five they had already typed come back empty. Every line is its own form and
    # every value is rendered from the server, so saving one line repaints all of
    # them with what the database knows — which, for a line not yet recorded, is
    # nothing.
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

    # Once it is saved, the draft is spent: the line must show what the database
    # accepted, not what was in the box before it was submitted.
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

    # The other half of the same rule, and the one the recount depends on: a
    # count that was taken but not believed must leave the field empty. Keeping
    # the number in it makes the second count a reading of the first.
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

      # The box stays: the goods are on that shelf whatever the count turns out
      # to be, and asking for it again is asking a question already answered.
      assert form =~ box.code
    end

    # "registrado" used to belong to whichever line was saved last, so counting
    # the second line took the tick off the first. Nothing about the first line
    # changed when the second was counted.
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

    # The tick may not push the row around when it appears: it lands under the
    # thumb of somebody typing into the next line down.
    test "the recorded tick is present before it is earned, only invisible", %{
      conn: conn,
      receipt: receipt
    } do
      line = line_for(receipt, 1)
      {:ok, _view, html} = live(conn, ~p"/receipts/#{receipt}")

      form = form_for_line(html, line)

      # Rendered, so the row is already the height it will be; hidden, so it
      # makes no claim about a line nobody has counted.
      assert form =~ "registrado"
      assert form =~ "invisible"
    end

    # CX-102 typed where CX-012 was meant is a box that exists, is empty, is
    # never opened, and holds the difference in somebody's stock forever. The
    # flash announcing the creation arrives after the goods are already in it.
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

      # Nothing written: not the box, and not the count that was riding on it.
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

      # The count that was waiting was taken — and, disagreeing with the
      # invoice, taken as a first count rather than as the answer. The box is
      # already recorded: the operator put the goods on a shelf, which is true
      # whichever way the arithmetic ends up.
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

      # The 287 they counted is still on the line: they mistyped the box, not
      # the count, and retyping the count is how a real number gets rounded.
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

      # Not booked, and not yet a divergence anybody reports: one count that
      # disagrees with the invoice is more often a miscount than a loss, and the
      # line goes back to asking. On the row, not in a flash — forty lines is
      # forty toasts over the table they are about.
      assert first =~ "Conte este item de novo"
      assert first =~ "contagem 2 de 3"
      refute first =~ "Divergências em relação à nota"

      html = count_line(view, receipt, line, "287", box.code)

      assert html =~ "registrado"
      assert html =~ "Divergências em relação à nota"
      assert html =~ "a nota diz 300, contamos 287"
      assert html =~ "-13"
      assert html =~ "3 linha(s) não contada(s)"

      # Counted three times, still short. Not the operator's to close alone.
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

      # Nobody is sent back to the shelf to confirm a number that already
      # matches. Counting again is the price of a disagreement, not a ritual.
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

      # Three different counts, and the last one is the one booked: it is the
      # count made with the most care, by an operator who now knows the first
      # two were disputed.
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

      # The trail goes with it. Keeping it would let the next single count land
      # as the third attempt and be believed on the spot, which is the rule
      # deleting itself.
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

      # The three lines nobody counted are untouched: 50 + 100 + 100.
      assert Decimal.equal?(
               Inventory.balance(location_id: warehouse.id, box_id: nil),
               Decimal.new(250)
             )
    end

    # The way back from a number typed wrong. Nothing has reached the ledger
    # yet — a conference writes at the close — so this is an edit, not an
    # adjustment.
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

      # Empty, not 287. A second count that starts from the first one is not a
      # second count — the eye stops at the number it was shown, which is what
      # this whole screen is built to prevent.
      assert form =~ ~s(name="counted_quantity" value="")

      # The box is kept: they mistyped a quantity, not the shelf.
      assert form =~ box.code

      # And the line is honestly uncounted again.
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

      # Same reasoning as the recorded tick: a control that appears on save
      # pushes the row below it down, and the row below it is where the thumb
      # already is.
      [button] =
        Regex.run(~r{<button[^>]*phx-click="count_again"[^>]*>}, form_for_line(html, line))

      assert button =~ "invisible"
      assert button =~ "disabled"
    end

    # "Deseja mesmo continuar ou voltar. O Voltar fica o botão melhor, o
    # Continuar mesmo assim fica o botão menos chamativo."
    test "closing with lines uncounted names them first", %{
      conn: conn,
      receipt: receipt,
      box: box
    } do
      {:ok, view, html} = live(conn, ~p"/receipts/#{receipt}")

      dialog = Regex.run(~r{<dialog[^>]*id="uncounted-warning".*?</dialog>}s, html) |> hd()

      # The products, not the number: "4 linhas" is not something anyone can
      # act on, and the answer is usually "that box is still in the van".
      assert dialog =~ "Produto 2"
      assert dialog =~ "Produto 3"

      # Going back is the loud button; continuing is offered plainly and is
      # never blocked. The order is the assertion — a primary "continue" is how
      # these dialogs are usually built and is exactly backwards.
      [{back, _}] = Regex.run(~r{btn btn-primary}, dialog, return: :index)
      [{anyway, _}] = Regex.run(~r{btn btn-ghost}, dialog, return: :index)
      assert anyway < back

      # The close button no longer submits on its own press.
      assert html =~ ~s(data-confirm-open="uncounted-warning")

      # And with everything counted, there is nothing to warn about.
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

    # Goods counted into no box are loose at the location, and loose stock
    # cannot travel: the next person to load a mission finds a quantity and
    # nothing to carry it in. The field says `required`; this is the rule
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
