defmodule EstoqueOSWeb.ReceiptLive.Show do
  @moduledoc """
  The receiving conference: count each line against the invoice and say which
  box it went into.

  Counting is unblocked (a round may finish with lines uncounted; uncounted is
  never zero), but a count that disagrees with the invoice is not booked on the
  first pass: the line empties and is counted again, up to
  `Receiving.counts_required/0` times. The screen stays blind: it names which
  line to recount, never by how much.

  A line that disagrees every time is recorded and flagged: the close posts an
  adjustment with a `review_reason` for the manager's overview.
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

  # Typed but not yet recorded. Every field renders from the server, so recording
  # one line repaints all of them and blanks the others; the draft outranks the
  # database until the line is saved.
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

  # Never counted, awaiting recount, and diverged after recounts, all derived
  # from the same lines so they cannot disagree.
  defp assign_counts(socket, receipt) do
    socket
    |> assign(:divergences, Receiving.divergences(receipt))
    |> assign(:uncounted, Receiving.uncounted_lines(receipt))
    |> assign(:recounting, Receiving.awaiting_recount_lines(receipt))
    # The close gate asks for both kinds: a line awaiting recount is work left too.
    |> assign(
      :outstanding,
      Receiving.uncounted_lines(receipt) ++ Receiving.awaiting_recount_lines(receipt)
    )
    |> assign(:disputed, Receiving.diverged_after_recounts(receipt))
  end

  # Swaps in only what the save changed, not a whole-conference refetch: the
  # invoice line and box list must not move while somebody is typing.
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

  # Computed once for the whole conference, not per line as it renders.
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
            <%!-- Widest column: an NF-e description is the longest string here, and capping it makes every line four rows tall. --%>
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

            <%!-- Not shown to the person counting (blind count, as in `BoxLive.Count`); only to whoever closes the conference. --%>
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
                <%!-- Empty, not an em dash: `quantity(nil)` renders "—", which the operator would have to clear. --%>
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
                <%!-- Required: loose stock cannot travel, and the conference is when the box is known. --%>
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
                <%!-- Locked once counted: a recorded line reopens only through "Count again". --%>
                <.button
                  variant="primary"
                  class="btn-sm"
                  disabled={recorded?(line)}
                  phx-disable-with={gettext("Saving...")}
                >
                  {gettext("Record")}
                </.button>

                <%!-- Tick and undo are always rendered, `invisible` until recorded, in one fixed-width slot: anything that appears on save moves the row under the thumb. The tick follows the line's own state, not the last save. --%>
                <div class="flex w-16 shrink-0 items-center justify-end gap-1">
                  <span
                    class={["text-success", not recorded?(line) && "invisible"]}
                    role="status"
                    title={gettext("recorded")}
                    aria-label={gettext("recorded")}
                    aria-hidden={not recorded?(line)}
                  >
                    <.icon name="hero-check-circle" class="size-5" />
                  </span>

                  <%!-- Costs an edit, not an adjustment: a conference writes at the close. Empties the field, since a recount that starts from the first number is not a recount. --%>
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

                <%!-- The reason is on the line, not a `title`: phones have no hover. --%>
                <p
                  :for={hint <- suggested(assigns, line)}
                  class="basis-full text-xs opacity-70 text-right"
                >
                  {gettext("Store in %{box} — %{reason}",
                    box: hint.box.code,
                    reason: suggestion_reason(hint)
                  )}
                </p>

                <%!-- Deliberate exception to "always render, never :if": a decision to answer before anything else, standing under its own field, holding the next tap inside itself. Reserving its height in every row would leave a sheet of blank space. --%>
                <.new_box_confirm
                  :if={@new_box && @new_box.line_id == line.id}
                  code={@new_box.code}
                  class="basis-full text-left"
                />

                <%!-- Same deliberate exception as the box banner. Never says by how much it was off. Not `flex-wrap` or `justify-end`: at phone width the icon would land on its own line. --%>
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
              <.status
                :if={ReceiptLine.diverged_after_recounts?(line)}
                kind={:needs_review}
                detail={gettext("counted %{count}x", count: ReceiptLine.attempts(line))}
              />
            </:col>

            <:col :let={line} :if={@receipt.status == "completed"} label={gettext("Box")}>
              <.box_code code={line.box && line.box.code} />
            </:col>

            <%!-- A difference is the expected number said backwards, so it is hidden with it. --%>
            <:col
              :let={line}
              :if={@sees_money?}
              label={gettext("Difference")}
              align={:right}
            >
              <span class={difference_class(line)}>{difference_label(line)}</span>
            </:col>

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

        <%!-- Not disabled: closing with lines uncounted is allowed (a short delivery everyone knows about). --%>
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

      <%!-- Names the products, not a count. Going back is the primary button, the reverse of the usual dialog; continuing is never blocked. --%>
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

          <%!-- Named apart: these were counted and did not match. Closing over them books the invoice's number; allowed, but not quietly. --%>
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

  # Must look different from an untouched line: both have an empty field.
  defp recount?(line), do: ReceiptLine.awaiting_recount?(line)

  # "2 of 3" tells the operator it will end, without revealing the target.
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
  # Typing, not saving: only remembers the line to survive the next repaint.
  def handle_event("draft", %{"line" => line_id} = params, socket) do
    {:noreply, put_draft(socket, String.to_integer(line_id), params)}
  end

  def handle_event("count", %{"line" => line_id} = params, socket) do
    resolve_and_count(socket, line_id, params, create: false)
  end

  # Replays the held count with permission to create the box.
  def handle_event("confirm_new_box", _params, socket) do
    %{line_id: line_id, params: params} = socket.assigns.new_box

    socket
    |> assign(:new_box, nil)
    |> resolve_and_count(line_id, params, create: true)
  end

  # The count stays as a draft: the box was mistyped, not the quantity.
  def handle_event("cancel_new_box", _params, socket) do
    %{line_id: line_id, params: params} = socket.assigns.new_box

    {:noreply,
     socket
     |> assign(:new_box, nil)
     |> put_draft(line_id, Map.put(params, "box_code", ""))}
  end

  # Back to uncounted with an empty field, so closing warns about it like any other.
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
      # No flash: forty lines would be forty toasts covering the table; the row says it.
      {:recorded, updated} ->
        {:noreply, replace_line(socket, updated)}

      # Counted, not believed yet: the field empties, since a recount starting
      # from the first number is not a recount.
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
