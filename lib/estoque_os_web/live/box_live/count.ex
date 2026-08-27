defmodule EstoqueOSWeb.BoxLive.Count do
  @moduledoc """
  Counting one box, blind, and then standing behind the number.

  The sheet does not show what the ledger presumes. Shown the expected number, a
  person counting a hundred gauzes finds ninety-eight and writes a hundred — not
  dishonestly, but because the eye stops when it reaches the answer it was given.
  A count that confirms the ledger it was copied from measures nothing.

  So the screen is three steps, and each one exists for a reason:

    1. **Count.** Blank lines are not counted and keep what the ledger presumed;
       recording an uncounted line as zero is how a stock becomes fiction.

    2. **Recount, if anything disagrees.** The lines that diverge are named —
       *which* items, never by how much — and counted again. A first count that
       disagrees with the ledger is as likely to be a miscount as a real loss,
       and the cheapest moment to tell them apart is while the box is still
       open.

    3. **Confirm.** Only now are the numbers shown side by side, and only now is
       anything written. By this point the count is fixed, so seeing the
       difference cannot bend it.

  If the second count still disagrees with the ledger, the adjustment is filed
  with a `review_reason` and the manager is shown it on the dashboard. Somebody
  counted the same box twice and the stock was still not what we thought.

  A manager may reveal what the ledger expected — the exception this screen
  otherwise exists to prevent. It is off by default, it is theirs alone, and
  taking it is written into the transaction's notes, so a count made with the
  answer in view is never later read as a blind one.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Auditing

  alias EstoqueOS.Inventory.Locations

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Counting is all draft until `commit`, which is the one event that posts
  adjustments. Revealing the expected figure, checking a count and starting
  over move nothing — they are how somebody standing in another role's shoes
  can see what this screen actually does.
  """
  def viewer_events, do: ~w(reveal check recount start_over)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    box = Locations.get_box!(id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Count of box %{code}", code: box.code))
     |> assign(:step, :count)
     |> assign(:result, nil)
     |> assign(:divergences, [])
     |> assign(:first_counts, %{})
     |> assign(:pending, %{})
     |> assign(:recount_lots, [])
     |> assign(:preview, [])
     |> assign(:revealed?, false)
     |> assign(:escalate?, false)
     |> assign_box(box)}
  end

  defp assign_box(socket, box) do
    socket
    |> assign(:box, box)
    |> assign(:rows, Auditing.count_sheet(box))
  end

  defp signed(%Decimal{} = value) do
    if Decimal.compare(value, 0) == :gt, do: "+#{quantity(value)}", else: quantity(value)
  end

  defp difference_class(%Decimal{} = value) do
    case Decimal.compare(value, 0) do
      :gt -> "text-success"
      :lt -> "text-error"
      :eq -> ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/boxes/#{@box}"} back_label={gettext("Box %{code}", code: @box.code)}>
        {gettext("Count of box %{code}", code: @box.code)}
        <:subtitle>
          {@box.location.name} · {verified_label(@box)}
        </:subtitle>
        <:actions>
          <.reveal_expected
            available?={@sees_money? and @step == :count and not @revealed?}
            revealed?={@revealed?}
          />
        </:actions>
      </.header>

      <div :if={@result} class="alert alert-success mt-4">
        {gettext("Count recorded: %{adjusted} lot(s) corrected out of %{counted} counted.",
          adjusted: @result.adjusted,
          counted: @result.counted
        )}
      </div>

      <p :if={@rows == []} class="mt-8 opacity-70">
        {gettext("The ledger presumes this box is empty.")}
      </p>

      <!-- STEP 1 — count, blind. -->
      <form :if={@step == :count and @rows != []} id="count-form" phx-submit="check" class="mt-6">
        <.data_table rows={@rows} row_id={&"row-#{&1.lot_id}"}>
          <:col :let={row} label={gettext("Product")} emphasis={:identity}>
            {row.product}
          </:col>
          <:col :let={row} label={gettext("Lot")}>
            {row.lot_number || gettext("unknown")}
          </:col>
          <:col :let={row} label={gettext("Expiry")}>
            <span class={expiry_class(row.expires_on)}>{date(row.expires_on)}</span>
          </:col>
          <:col :let={row} :if={@revealed?} label={gettext("Ledger presumes")} align={:right}>
            {quantity(row.quantity)}
          </:col>
          <:col :let={row} label={gettext("Counted")} align={:right} field={:inline}>
            <.count_field
              name={"counts[#{row.lot_id}]"}
              label={gettext("Counted quantity for lot %{lot}", lot: row.lot_number || "—")}
            />
          </:col>
        </.data_table>

        <div class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-4">
          <.button variant="primary" phx-disable-with={gettext("Checking...")}>
            {gettext("Record count")}
          </.button>
          <.blank_note />
        </div>
      </form>

      <!-- STEP 2 — recount, naming the items but never the gap. -->
      <form :if={@step == :recount} id="recount-form" phx-submit="recount" class="mt-6">
        <.recount_notice count={length(@recount_lots)} />

        <.data_table rows={@recount_lots} row_id={&"recount-#{&1.lot_id}"}>
          <:col :let={row} label={gettext("Product")} emphasis={:identity}>
            {row.product}
          </:col>
          <:col :let={row} label={gettext("Lot")}>
            {row.lot_number || gettext("unknown")}
          </:col>
          <:col :let={row} label={gettext("Count again")} align={:right} field={:inline}>
            <.count_field
              name={"counts[#{row.lot_id}]"}
              label={gettext("Second count for lot %{lot}", lot: row.lot_number || "—")}
            />
          </:col>
        </.data_table>

        <div class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-4">
          <.button variant="primary" phx-disable-with={gettext("Checking...")}>
            {gettext("Confirm the second count")}
          </.button>
        </div>
      </form>

      <!-- STEP 3 — what will change, before anything changes. -->
      <div :if={@step == :confirm} class="mt-6">
        <.panel
          title={gettext("What this count will change")}
          note={gettext("Nothing has been written yet.")}
          flush
        >
          <.data_table rows={@preview} row_id={&"change-#{&1.lot_id}"}>
            <:empty>
              <.empty
                icon="hero-check-circle"
                title={gettext("Everything counted matched the ledger.")}
                note={gettext("Recording this changes no quantity; it marks the box as counted.")}
              />
            </:empty>

            <:col :let={row} label={gettext("Product")} emphasis={:identity}>{row.product}</:col>
            <:col :let={row} label={gettext("Lot")}>
              {row.lot_number || gettext("unknown")}
            </:col>
            <:col :let={row} label={gettext("Ledger presumed")} align={:right}>
              {quantity(row.presumed)}
            </:col>
            <:col :let={row} label={gettext("Counted")} align={:right}>
              {quantity(row.counted)}
            </:col>
            <:col :let={row} label={gettext("Difference")} align={:right} emphasis={:primary}>
              <span class={difference_class(row.difference)}>{signed(row.difference)}</span>
            </:col>
          </.data_table>
        </.panel>

        <p :if={@escalate?} class="alert alert-warning mt-4">
          {gettext(
            "Counted twice and still different. Recording this will flag the box for the manager."
          )}
        </p>

        <form id="commit-form" phx-submit="commit" class="hidden"></form>

        <div class="flex flex-wrap items-center gap-3 border-t border-base-300 pt-4 mt-4">
          <.commit_action
            id="confirm-count"
            form="commit-form"
            label={gettext("Save this count")}
            title={gettext("Save this count?")}
          >
            <:consequence>
              <p>
                {gettext("%{count} lot(s) change; the box is marked as counted today.",
                  count: changing(@preview)
                )}
              </p>
            </:consequence>
          </.commit_action>

          <.button variant="ghost" type="button" phx-click="start_over">
            {gettext("Count again from the start")}
          </.button>
        </div>
      </div>

      <!-- After recording. -->
      <section :if={@step == :done and @divergences != []} class="mt-8">
        <h2 class="font-semibold">{gettext("What the count changed")}</h2>
        <p class="text-sm text-base-content/70">
          {gettext("The ledger had presumed these numbers; the count corrected them.")}
        </p>

        <.data_table rows={@divergences} row_id={&"divergence-#{&1.lot_id}"}>
          <:col :let={row} label={gettext("Product")} emphasis={:identity}>{row.product}</:col>
          <:col :let={row} label={gettext("Lot")}>
            {row.lot_number || gettext("unknown")}
          </:col>
          <:col :let={row} label={gettext("Ledger presumed")} align={:right}>
            {quantity(row.presumed)}
          </:col>
          <:col :let={row} label={gettext("Counted")} align={:right}>
            {quantity(row.counted)}
          </:col>
          <:col :let={row} label={gettext("Difference")} align={:right} emphasis={:primary}>
            <span class={difference_class(row.difference)}>{signed(row.difference)}</span>
          </:col>
        </.data_table>
      </section>

      <p :if={@step == :done and @divergences == []} class="alert alert-success mt-8">
        {gettext("Every line counted matched what the ledger presumed.")}
      </p>
    </Layouts.app>
    """
  end

  defp verified_label(%{last_verified_at: nil}), do: gettext("never counted")

  defp verified_label(%{last_verified_at: verified_at}) do
    gettext("counted on %{date}", date: date(verified_at))
  end

  defp expiry_class(nil), do: ""

  defp expiry_class(date) do
    cond do
      Date.before?(date, Date.utc_today()) -> "text-error font-medium"
      Date.diff(date, Date.utc_today()) <= 90 -> "text-warning"
      true -> ""
    end
  end

  @impl true
  def handle_event("reveal", _params, socket) do
    if socket.assigns.sees_money? do
      {:noreply, assign(socket, :revealed?, true)}
    else
      {:noreply, socket}
    end
  end

  # First submit. Nothing is written: either the numbers agree with the ledger
  # and we go straight to the confirmation, or they do not and the same items
  # get counted a second time.
  def handle_event("check", params, socket) do
    counts = submitted_counts(params)
    divergent = Auditing.divergent(socket.assigns.box, counts)

    if divergent == [] do
      {:noreply, to_confirm(socket, counts, false)}
    else
      {:noreply,
       socket
       |> assign(:step, :recount)
       |> assign(:first_counts, counts)
       |> assign(:recount_lots, rows_for(socket.assigns.rows, divergent))}
    end
  end

  # Second submit. The recounted lines replace the first numbers; whatever was
  # counted only once and agreed the first time stands.
  def handle_event("recount", params, socket) do
    counts = Map.merge(socket.assigns.first_counts, submitted_counts(params))

    # Still short of the ledger after two counts. That is no longer a miscount,
    # and it is not the counter's to close alone.
    escalate? = Auditing.divergent(socket.assigns.box, counts) != []

    {:noreply, to_confirm(socket, counts, escalate?)}
  end

  def handle_event("start_over", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :count)
     |> assign(:first_counts, %{})
     |> assign(:pending, %{})
     |> assign(:recount_lots, [])
     |> assign(:preview, [])}
  end

  def handle_event("commit", _params, socket) do
    box = socket.assigns.box
    counts = socket.assigns.pending
    divergences = describe(socket.assigns.rows, Auditing.preview_count(box, counts))

    opts = [
      user_id: socket.assigns.current_scope.user.id,
      recounted: socket.assigns.first_counts != %{},
      revealed: socket.assigns.revealed?,
      review_reason: socket.assigns.escalate? && "count_diverged_twice"
    ]

    case Auditing.record_count(box, counts, opts) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:step, :done)
         |> assign(:result, result)
         |> assign(:divergences, Enum.reject(divergences, &Decimal.equal?(&1.difference, 0)))
         |> put_flash(:info, count_message(socket.assigns.escalate?))
         |> assign_box(Locations.get_box!(box.id))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The count could not be recorded."))}
    end
  end

  defp count_message(true) do
    gettext("Box counted, and flagged for the manager: it disagreed twice.")
  end

  defp count_message(false), do: gettext("Box counted and marked as verified.")

  defp to_confirm(socket, counts, escalate?) do
    socket
    |> assign(:step, :confirm)
    |> assign(:pending, counts)
    |> assign(:escalate?, escalate?)
    |> assign(
      :preview,
      describe(socket.assigns.rows, Auditing.preview_count(socket.assigns.box, counts))
    )
  end

  defp submitted_counts(params) do
    params
    |> Map.get("counts", %{})
    |> Enum.reject(fn {_lot_id, value} -> String.trim(value) == "" end)
    |> Map.new()
  end

  # The ledger rows know the numbers; the count sheet knows what the things are
  # called. The screen needs both.
  # What the dialog promises has to be what the result reports. It counted every
  # line somebody typed into, so a count where one of two lines matched the
  # ledger announced "2 lote(s) mudam" and then recorded "1 lote(s)
  # corrigido(s) de 2 contado(s)".
  defp changing(preview) do
    Enum.count(preview, &(not Decimal.equal?(&1.difference, 0)))
  end

  defp describe(rows, lines) do
    Enum.map(lines, fn line ->
      row = Enum.find(rows, &(&1.lot_id == line.lot_id)) || %{product: "—", lot_number: nil}
      Map.merge(line, %{product: row.product, lot_number: row.lot_number})
    end)
  end

  defp rows_for(rows, divergent) do
    lot_ids = MapSet.new(divergent, & &1.lot_id)
    Enum.filter(rows, &MapSet.member?(lot_ids, &1.lot_id))
  end
end
