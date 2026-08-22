defmodule EstoqueOSWeb.ReceiptLive.Show do
  @moduledoc """
  The receiving conference: count each line against the invoice and say which
  box it went into.

  Counting is deliberately unblocked — you can finish a round having counted
  three of ten lines. What was not counted is reported as not counted, never
  as zero.

  What is *not* unblocked is the number itself. A count that disagrees with the
  invoice is not booked on the first pass: the field empties and the line asks
  to be counted again, up to `Receiving.counts_required/0` times, and only then
  is the number believed. Until this existed the operator could type any
  quantity at all against an invoice that said something else, which is the
  same hole `BoxLive.Count` was built to close for box counts.

  The screen stays blind throughout. It says *which* line to count again and
  never by how much it was off — told the target, a person counting a hundred
  gauzes finds ninety-eight and writes a hundred.

  A line that disagreed every time it was counted is recorded as counted and
  flagged: the adjustment posted at the close carries a `review_reason`, and it
  surfaces on the manager's overview. Somebody counted the same goods three
  times and we still do not agree with the invoice — that is a conversation
  with the supplier, not a number for the operator to settle alone.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Receiving
  alias EstoqueOS.Receiving.ReceiptLine

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    receipt = Receiving.get_receipt!(id)

    {:ok,
     socket
     |> assign(
       :page_title,
       gettext("Receiving of invoice %{number}", number: receipt.invoice.number)
     )
     |> assign(:boxes, boxes_at(receipt.location_id))
     |> assign(:drafts, %{})
     |> assign(:new_box, nil)
     |> assign_receipt(receipt)}
  end

  # What has been typed into a line but not yet recorded.
  #
  # Every line is its own form and every field is rendered from the server, so
  # recording one line repaints all of them — and for a line the database has
  # never heard of, the server's answer is blank. An operator counting six boxes
  # onto one screen recorded the first and lost the five they had already typed.
  #
  # So the typing is kept here, and the draft outranks the database until the
  # line is saved, at which point it is dropped and the saved number takes over.
  defp draft(assigns, line, field) do
    assigns.drafts |> Map.get(line.id, %{}) |> Map.get(field)
  end

  defp put_draft(socket, line_id, params) do
    draft = Map.take(params, ~w(counted_quantity box_code))
    assign(socket, :drafts, Map.put(socket.assigns.drafts, line_id, draft))
  end

  defp drop_draft(socket, line_id) do
    assign(socket, :drafts, Map.delete(socket.assigns.drafts, line_id))
  end

  defp assign_receipt(socket, receipt) do
    socket
    |> assign(:receipt, receipt)
    |> assign_counts(receipt)
    |> assign(:suggestions, suggestions_for(receipt))
  end

  # The three ways a line can be outstanding, all derived from the same list so
  # they can never disagree about a line: never counted, counted and waiting to
  # be counted again, and counted repeatedly and still short.
  defp assign_counts(socket, receipt) do
    socket
    |> assign(:divergences, Receiving.divergences(receipt))
    |> assign(:uncounted, Receiving.uncounted_lines(receipt))
    |> assign(:recounting, Receiving.awaiting_recount_lines(receipt))
    # Everything still owed before this conference is finished, of either kind.
    # The close gate asks this rather than either list on its own: a line
    # waiting for its second count is work left, exactly like one nobody
    # opened.
    |> assign(
      :outstanding,
      Receiving.uncounted_lines(receipt) ++ Receiving.awaiting_recount_lines(receipt)
    )
    |> assign(:disputed, Receiving.diverged_after_recounts(receipt))
  end

  # Recording one line used to refetch the whole conference, which re-rendered
  # forty rows and re-ran the box suggestions for all of them. Only what the
  # save actually changed is swapped in: the invoice line and the box list are
  # facts about the delivery and the warehouse, not about this count, and they
  # have no business moving while somebody is typing into them.
  defp replace_line(socket, %ReceiptLine{} = updated) do
    lines =
      Enum.map(socket.assigns.receipt.lines, fn
        %{id: id} = line when id == updated.id ->
          %{
            line
            | counted_quantity: updated.counted_quantity,
              count_attempts: updated.count_attempts,
              box_id: updated.box_id,
              box: box_for(socket, updated.box_id)
          }

        line ->
          line
      end)

    receipt = %{socket.assigns.receipt | lines: lines}

    socket
    |> assign(:receipt, receipt)
    |> assign_counts(receipt)
    |> drop_draft(updated.id)
  end

  defp box_for(_socket, nil), do: nil
  defp box_for(socket, box_id), do: Enum.find(socket.assigns.boxes, &(&1.id == box_id))

  # Computed once for the whole conference rather than per line as it renders: a
  # delivery is dozens of lines and the warehouse's contents do not change
  # between two of them.
  defp suggestions_for(receipt) do
    receipt.lines
    |> Enum.map(& &1.invoice_item.product_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(&{&1, Locations.suggest_boxes(&1, receipt.location_id, limit: 2)})
  end

  defp boxes_at(location_id), do: Locations.list_boxes(location_id)

  defp suggested(assigns, line) do
    if line.box_id,
      do: [],
      else: Map.get(assigns.suggestions, line.invoice_item.product_id, [])
  end

  defp suggestion_reason(%{reason: :same_product, because: name}) do
    gettext("already holds %{product} — one product, one box", product: name)
  end

  defp suggestion_reason(%{reason: :same_group, because: name}) do
    gettext("holds %{product}, from the same group", product: name)
  end

  defp suggestion_reason(%{reason: :same_sector, because: sector}) do
    gettext("holds %{sector} items", sector: sector)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/conferences"} back_label={gettext("Conference")}>
        {gettext("Receiving of invoice %{number}", number: @receipt.invoice.number)}
        <:subtitle>
          {gettext("Round %{round} · %{location}",
            round: @receipt.round,
            location: @receipt.location.name
          )}
        </:subtitle>
        <:actions>
          <.status
            :if={@receipt.status == "completed"}
            kind={:complete}
            detail={gettext("Conference closed")}
          />
          <.status
            :if={@receipt.status == "draft" and @uncounted != []}
            kind={:pending}
            detail={gettext("%{count} line(s) not counted", count: length(@uncounted))}
          />
          <!-- Separate from "not counted", because it is a different job: those
               lines have not been visited, these have been visited and are
               waiting for the operator to go back to the shelf. -->
          <.status
            :if={@receipt.status == "draft" and @recounting != []}
            kind={:recount}
            detail={gettext("%{count} line(s) to count again", count: length(@recounting))}
          />
        </:actions>
      </.header>

      <div
        :if={@divergences != [] and @sees_money?}
        class="alert alert-warning flex-col items-start gap-2 mt-4"
      >
        <p class="font-semibold">{gettext("Divergences against the invoice")}</p>
        <ul class="list-disc list-inside text-sm">
          <li :for={divergence <- @divergences}>
            {gettext("%{description}: invoice says %{expected}, counted %{counted} (%{difference})",
              description: divergence.description,
              expected: quantity(divergence.expected),
              counted: quantity(divergence.counted),
              difference: format_signed(divergence.difference)
            )}
          </li>
        </ul>
      </div>

      <.box_options id="receipt-boxes" boxes={@boxes} />

      <div class="mt-4">
        <.panel id="receipt-lines" title={gettext("Lines to conference")} flush>
          <.data_table rows={@receipt.lines} row_id={&"line-#{&1.id}"}>
            <!-- The widest column on the screen, and it was one of the
                 narrowest: an NF-e line description is the longest string in
                 this whole system — "COMPRESSA GAZE 7,5X7,5CM 13F 9 FIOS PCT
                 C/10 UNID" — and it was capped at `max-w-md` while a quantity
                 field beside it had the same room. Capping it made every line
                 four rows tall, which is what the person reading the DANFE
                 beside the screen has to scan. -->
            <:col
              :let={line}
              label={gettext("Invoice line")}
              emphasis={:identity}
              width="w-[38%]"
            >
              <div>
                <p class="font-medium">{line.invoice_item.description}</p>
                <p class="text-xs opacity-60">
                  {product_name(line)}
                  <span :if={line.invoice_item.lot_number}>
                    · {gettext("lot %{lot}", lot: line.invoice_item.lot_number)}
                  </span>
                </p>
              </div>
            </:col>

            <!-- Not shown to the person doing the counting. This is the same
                 rule `BoxLive.Count` was built on, and the conference used to
                 contradict it: told what to find, an operator counting a hundred
                 gauzes finds ninety-eight and writes a hundred. The number is
                 there for whoever closes the conference and reads what it
                 found. -->
            <:col
              :let={line}
              :if={@sees_money?}
              label={gettext("Invoice says")}
              align={:right}
            >
              {quantity(line.expected_quantity)}
            </:col>

            <:col
              :let={line}
              :if={@receipt.status == "draft"}
              label={gettext("Counted")}
              align={:right}
              field={:block}
            >
              <form
                id={"count-#{line.id}"}
                phx-submit="count"
                phx-change="draft"
                phx-value-line={line.id}
                class="flex flex-wrap items-center gap-2 justify-end"
              >
                <!-- Empty, not an em dash. `quantity(nil)` renders "—", so an
                     uncounted line arrived with a character the operator had to
                     clear before typing the number they were holding. -->
                <.count_field
                  name="counted_quantity"
                  value={draft(assigns, line, "counted_quantity") || counted_value(line)}
                  label={
                    gettext("Counted quantity of %{product}",
                      product: line.invoice_item.description
                    )
                  }
                  disabled={recorded?(line)}
                  phx-debounce="400"
                />
                <!-- Required. Goods recorded with no box are loose at the
                     location, and loose stock cannot travel: the next person
                     to load a mission finds a quantity and nothing to carry it
                     in. The conference is the moment the box is known, because
                     the operator is holding it. -->
                <.box_picker
                  name="box_code"
                  boxes={@boxes}
                  list_id="receipt-boxes"
                  value={draft(assigns, line, "box_code") || (line.box && line.box.code)}
                  label={gettext("Box")}
                  phx-debounce="400"
                  disabled={recorded?(line)}
                  required
                />
                <!-- Locked once counted: a recorded line reopens on purpose,
                     through "Count again", never by nudging a field that looks
                     editable because it still is one. -->
                <.button
                  variant="primary"
                  class="btn-sm"
                  disabled={recorded?(line)}
                  phx-disable-with={gettext("Saving...")}
                >
                  {gettext("Record")}
                </.button>

                <!-- Always rendered, so the row is the height it will be before
                     anything is counted. A tick that appears on save pushes the
                     row below it down, and the row below it is where the thumb
                     already is.

                     It belongs to the line, not to the last save: it used to be
                     `line.id == @saved_line_id`, so counting the second line
                     took the confirmation off the first, and an operator working
                     down a delivery could never see how far they had got. -->
                <!-- Both always rendered, and in one slot of a fixed width, so
                     the row is already the height and width it will be before
                     anything is counted. Anything that appears on save pushes
                     the row below it down, and the row below it is where the
                     thumb already is. The first attempt put the tick and the
                     button side by side in the wrapping row: the button wrapped
                     to a second line on the counted row only, which is the same
                     bug wearing a hat. -->
                <div class="flex w-16 shrink-0 items-center justify-end gap-1">
                  <!-- Both marks are icons now. The words took a column of
                       width from the numbers on a screen read one-handed, and
                       what they say is said better by a tick and an arrow going
                       back. Named for the screen reader and on hover, which is
                       the only thing that makes an icon-only control allowed.

                       Both are always rendered and only made invisible: the
                       first version wrapped onto a second line on the counted
                       row alone, which is the row-resize bug wearing a hat.

                       The tick belongs to the line, not to the last save — it
                       used to be `line.id == @saved_line_id`, so counting the
                       second line took the confirmation off the first, and an
                       operator working down a delivery could never see how far
                       they had got. -->
                  <span
                    class={["text-success", not recorded?(line) && "invisible"]}
                    role="status"
                    title={gettext("recorded")}
                    aria-label={gettext("recorded")}
                    aria-hidden={not recorded?(line)}
                  >
                    <.icon name="hero-check-circle" class="size-5" />
                  </span>

                  <!-- The way back from a number typed wrong. Nothing has
                       reached the ledger yet — a conference writes at the
                       close — so this costs an edit, not an adjustment.

                       It empties the field rather than leaving the first count
                       in it. A second count that starts from the first one is
                       not a second count: the eye stops when it reaches the
                       number it was shown, which is the whole reason this
                       screen is blind. -->
                  <button
                    type="button"
                    phx-click="count_again"
                    phx-value-line={line.id}
                    class={["btn btn-ghost btn-xs btn-square", not recorded?(line) && "invisible"]}
                    disabled={not recorded?(line)}
                    title={gettext("Count again")}
                    aria-label={gettext("Count again")}
                    aria-hidden={not recorded?(line)}
                  >
                    <.icon name="hero-arrow-uturn-left" class="size-4" />
                  </button>
                </div>

                <!-- A warehouse organised by whoever was holding the scanner is a
                     warehouse where finding anything means opening everything.
                     The reason is on the line rather than in a `title`: this is
                     read on a phone, where nothing is hovered, and a bare box
                     code is a suggestion nobody trusts enough to follow. -->
                <p
                  :for={hint <- suggested(assigns, line)}
                  class="basis-full text-xs opacity-70 text-right"
                >
                  {gettext("Store in %{box} — %{reason}",
                    box: hint.box.code,
                    reason: suggestion_reason(hint)
                  )}
                </p>

                <!-- Asked before anything is written, and it names the code out
                     loud: the whole failure this prevents is a code that looks
                     right at a glance.

                     Under the field it is about, not at the top of the page. It
                     was a banner above forty rows, which asked about a box the
                     operator had typed somewhere off screen and made them find
                     the line again to fix it. Here it needs no "For: ..." line
                     to say which line it means — it is standing on it. -->
                <!-- Grows the row it's in, unlike the tick/undo pair above — a
                     deliberate exception to "always render, never :if". Those
                     are passive confirmations glanced at while the thumb is
                     already moving to the next line, so a shift there lands the
                     next tap on the wrong one. This banner is a decision the
                     operator must answer before doing anything else; it appears
                     exactly where they are already looking and holds their next
                     tap inside itself, not on the line below. Reserving its
                     height in every line instead was tried and rejected: this
                     screen runs to "forty rows" (see the comment above), and
                     that is a conference sheet mostly made of blank space for a
                     banner that a correct box code never shows. -->
                <.new_box_confirm
                  :if={@new_box && @new_box.line_id == line.id}
                  code={@new_box.code}
                  class="basis-full text-left"
                />

                <!-- The line asking to be counted again. Same deliberate
                     exception as the box banner above: it grows the row, and it
                     is allowed to, because it is a decision the operator has to
                     answer before moving on rather than a confirmation glanced
                     at while the thumb is already on the next line. Reserving
                     its height in all forty rows would be a conference sheet
                     made mostly of blank space for something a count that
                     agrees never shows.

                     It never says by how much. Which line, and which attempt —
                     told the target, the eye stops when it reaches it. -->
                <!-- Not `flex-wrap`, and not `justify-end` like the row it sits
                     in: at phone width the icon was pushed onto a line of its
                     own, right-aligned, above the sentence it belongs to. -->
                <div
                  :if={recount?(line)}
                  class="basis-full flex items-start gap-2 rounded-box bg-warning/15 px-2 py-1.5 text-left"
                >
                  <.icon name="hero-arrow-path" class="size-4 shrink-0 mt-0.5 text-warning" />
                  <p class="text-sm">
                    <span class="font-medium">{gettext("Count this one again.")}</span>
                    <span class="opacity-80">
                      {gettext("It does not match the invoice — %{attempt}.",
                        attempt: attempt_label(line)
                      )}
                    </span>
                  </p>
                </div>
              </form>
            </:col>

            <:col
              :let={line}
              :if={@receipt.status == "completed"}
              label={gettext("Counted")}
              align={:right}
            >
              {quantity(line.counted_quantity) |> blank_as_dash()}
              <!-- Counted three times and never agreed. Worth saying on the
                   closed sheet: read a month later, a line that is simply short
                   and a line somebody counted three times are the same number,
                   and only one of them is evidence. -->
              <.status
                :if={ReceiptLine.diverged_after_recounts?(line)}
                kind={:needs_review}
                detail={gettext("counted %{count}x", count: ReceiptLine.attempts(line))}
              />
            </:col>

            <:col :let={line} :if={@receipt.status == "completed"} label={gettext("Box")}>
              <.box_code code={line.box && line.box.code} />
            </:col>

            <!-- A difference is the expected number said backwards: told a line
                 is 13 short, the operator knows what the invoice claimed. -->
            <:col
              :let={line}
              :if={@sees_money?}
              label={gettext("Difference")}
              align={:right}
            >
              <span class={difference_class(line)}>{difference_label(line)}</span>
            </:col>

            <!-- What the operator gets instead: whether this line is done. -->
            <:col :let={line} :if={not @sees_money?} label={gettext("Status")} align={:right}>
              <.status
                :if={is_nil(line.counted_quantity) and not recount?(line)}
                kind={:pending}
                detail={gettext("to count")}
              />
              <.status :if={recount?(line)} kind={:recount} />
              <.status :if={line.counted_quantity} kind={:counted} />
            </:col>
          </.data_table>
        </.panel>
      </div>

      <form
        :if={@receipt.status == "draft"}
        id="complete-form"
        phx-submit="complete"
        class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-4"
      >
        <.button
          :if={@outstanding == []}
          variant="primary"
          phx-disable-with={gettext("Closing...")}
        >
          {gettext("Close conference")}
        </.button>

        <!-- Same button, one step further away, when there is something to say
             first. Not disabled: closing with lines uncounted is allowed and
             sometimes right — the delivery is short and everyone knows it. -->
        <.button
          :if={@outstanding != []}
          variant="primary"
          type="button"
          data-confirm-open="uncounted-warning"
        >
          {gettext("Close conference")}
        </.button>

        <p class="text-sm opacity-70">
          {gettext("Lines left uncounted stay exactly as the invoice booked them.")}
        </p>
      </form>

      <!-- The products, not the number. "4 lines were not counted" is not
           something anyone can act on; the operator has to know *which*, because
           the answer is usually "the box is still in the van".

           The weighting is deliberate and is the opposite of how these dialogs
           are usually built: going back is the primary button, because it is
           what the operator almost always wants once they read the list.
           Continuing is offered plainly, in a ghost, and is never blocked. -->
      <dialog :if={@outstanding != []} id="uncounted-warning" class="modal">
        <div class="modal-box">
          <h2 class="text-lg font-semibold">
            {gettext("%{count} line(s) are still open.", count: length(@outstanding))}
          </h2>

          <div :if={@uncounted != []}>
            <p class="mt-3 text-sm font-semibold">
              {gettext("%{count} nobody counted:", count: length(@uncounted))}
            </p>
            <ul class="mt-1 list-disc list-inside text-sm space-y-1 max-h-64 overflow-y-auto">
              <li :for={line <- @uncounted}>{product_name(line)}</li>
            </ul>
          </div>

          <p class="mt-3 text-sm opacity-70">
            {gettext("Closing now books these exactly as the invoice said, uncounted.")}
          </p>

          <!-- Named apart, because these are not lines nobody looked at: they
               were counted, the number did not match the invoice, and the
               recount they are waiting for is the whole point of asking twice.
               Closing over them books the invoice's number and leaves the
               operator's first count as a note nobody reads. Still allowed —
               the van left, the delivery is short and everyone knows it — but
               it should not be allowed quietly. -->
          <div :if={@recounting != []} class="mt-3 rounded-box bg-warning/15 p-3">
            <p class="text-sm font-semibold">
              {gettext("%{count} were counted and did not match:", count: length(@recounting))}
            </p>
            <ul class="mt-1 list-disc list-inside text-sm space-y-1">
              <li :for={line <- @recounting}>{product_name(line)}</li>
            </ul>
            <p class="mt-2 text-sm opacity-80">
              {gettext(
                "Counting them again is what tells a miscount from a delivery that came short."
              )}
            </p>
          </div>

          <div class="modal-action">
            <.button
              variant="ghost"
              type="submit"
              form="complete-form"
              phx-disable-with={gettext("Closing...")}
            >
              {gettext("Close anyway")}
            </.button>
            <button type="button" data-confirm-close class="btn btn-primary">
              {gettext("Go back and count")}
            </button>
          </div>
        </div>

        <form method="dialog" class="modal-backdrop">
          <button aria-label={gettext("Close")}>{gettext("Close")}</button>
        </form>
      </dialog>

      <div :if={@receipt.status == "completed"} class="mt-6 flex gap-4">
        <.link navigate={~p"/invoices/#{@receipt.invoice_id}"} class="link link-hover text-sm">
          {gettext("Back to the invoice")}
        </.link>
        <.link navigate={~p"/stock"} class="link link-hover text-sm">{gettext("See stock")}</.link>
      </div>
    </Layouts.app>
    """
  end

  defp product_name(%{invoice_item: %{product: %{name: name}}}), do: name
  defp product_name(_line), do: gettext("product not resolved")

  defp counted_value(%{counted_quantity: nil}), do: ""
  defp counted_value(%{counted_quantity: counted}), do: quantity(counted)

  defp recorded?(%{counted_quantity: nil}), do: false
  defp recorded?(_line), do: true

  # Counted once and not believed. A different row from one nobody has touched,
  # and it has to look different: both have an empty field, and only one of them
  # is asking the operator to go back to the shelf.
  defp recount?(line), do: ReceiptLine.awaiting_recount?(line)

  # Which count this is, said out loud. "2 de 3" tells the operator this will
  # end, which is what stops the screen feeling like it is refusing their work
  # — and it says nothing about the number they are being measured against.
  defp attempt_label(line) do
    gettext("count %{n} of %{total}",
      n: ReceiptLine.attempts(line) + 1,
      total: Receiving.counts_required()
    )
  end

  defp difference_label(line) do
    case ReceiptLine.divergence(line) do
      nil -> gettext("not counted")
      difference -> format_signed(difference)
    end
  end

  defp difference_class(line) do
    cond do
      is_nil(line.counted_quantity) -> "opacity-60 text-xs"
      ReceiptLine.diverges?(line) -> "text-error"
      true -> "text-success"
    end
  end

  @impl true
  # Typing, not saving. Nothing reaches the database here; this only remembers
  # the line well enough to survive the next repaint.
  def handle_event("draft", %{"line" => line_id} = params, socket) do
    {:noreply, put_draft(socket, String.to_integer(line_id), params)}
  end

  def handle_event("count", %{"line" => line_id} = params, socket) do
    resolve_and_count(socket, line_id, params, create: false)
  end

  # The yes. The code and the count that was riding on it were held rather than
  # written, so this replays the same submission with permission to create.
  def handle_event("confirm_new_box", _params, socket) do
    %{line_id: line_id, params: params} = socket.assigns.new_box

    socket
    |> assign(:new_box, nil)
    |> resolve_and_count(line_id, params, create: true)
  end

  # The no. The count stays on the line as a draft: they mistyped the box, not
  # the quantity, and making them count the goods again is how a real number
  # gets replaced with a remembered one.
  def handle_event("cancel_new_box", _params, socket) do
    %{line_id: line_id, params: params} = socket.assigns.new_box

    {:noreply,
     socket
     |> assign(:new_box, nil)
     |> put_draft(line_id, Map.put(params, "box_code", ""))}
  end

  # Back to uncounted, and with an empty field. The line then reads as work still
  # to do — which it is — so closing the conference warns about it like any other
  # line nobody counted.
  def handle_event("count_again", %{"line" => line_id}, socket) do
    line = find_line(socket.assigns.receipt, line_id)

    case Receiving.uncount_line(line) do
      {:ok, updated} ->
        {:noreply, socket |> replace_line(updated) |> put_draft(updated.id, %{})}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("This line could not be reopened."))}
    end
  end

  def handle_event("complete", _params, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Receiving.complete_receipt(socket.assigns.receipt, user_id: user_id) do
      {:ok, %{receipt: receipt}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Conference closed and stock updated."))
         |> assign_receipt(receipt)}

      {:error, :receipt_not_open} ->
        {:noreply, put_flash(socket, :error, gettext("This conference is already closed."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The conference could not be closed."))}
    end
  end

  defp resolve_and_count(socket, line_id, params, opts) do
    line = find_line(socket.assigns.receipt, line_id)

    case Locations.resolve_box(params["box_code"], socket.assigns.receipt.location_id, opts) do
      # `required` on the field is presentation; this is the rule. Goods counted
      # into no box are loose at the location, and loose stock cannot travel.
      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, gettext("Say which box the goods went into."))}

      {:ok, box} ->
        record_count(socket, line, box, params)

      {:unknown, code} ->
        {:noreply,
         assign(socket, :new_box, %{code: code, line_id: line.id, line: line, params: params})}

      {:created, box} ->
        socket
        |> assign(:boxes, boxes_at(socket.assigns.receipt.location_id))
        |> put_flash(:info, gettext("Box %{code} created here.", code: box.code))
        |> record_count(line, box, params)

      {:error, {:box_elsewhere, box}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Box %{code} is somewhere else. Move it first, or use another.",
             code: box.code
           )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That box code could not be used."))}
    end
  end

  defp record_count(socket, line, box, params) do
    attrs = %{
      counted_quantity: params["counted_quantity"],
      box_id: box && box.id
    }

    case Receiving.record_count(line, attrs) do
      # No flash. Forty lines is forty toasts covering the table they are about,
      # and a banner that appears on every keystroke-and-enter reads as the page
      # reloading. The row says it itself, where the operator is already looking.
      {:recorded, updated} ->
        {:noreply, replace_line(socket, updated)}

      # Counted, and not believed yet. The field goes back to empty rather than
      # keeping the first number: a second count that starts from the first one
      # is not a second count — the eye stops when it reaches the number it was
      # shown, which is the whole reason this screen is blind.
      {:recount, updated} ->
        {:noreply, socket |> replace_line(updated) |> put_draft(updated.id, %{})}

      {:error, :invalid_quantity} ->
        {:noreply, put_flash(socket, :error, gettext("Type the counted quantity as a number."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Type the counted quantity as a number."))}
    end
  end

  defp find_line(receipt, line_id) when is_binary(line_id) do
    find_line(receipt, String.to_integer(line_id))
  end

  defp find_line(receipt, line_id) do
    Enum.find(receipt.lines, &(&1.id == line_id))
  end

  defp blank_as_dash(""), do: "—"
  defp blank_as_dash(value), do: value

  defp format_signed(value) do
    if Decimal.negative?(value) do
      quantity(value)
    else
      "+" <> quantity(value)
    end
  end
end
