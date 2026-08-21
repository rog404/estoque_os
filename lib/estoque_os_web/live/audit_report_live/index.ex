defmodule EstoqueOSWeb.AuditReportLive.Index do
  @moduledoc """
  The report a Brazilian auditor asks for: what moved in a period, what was
  adjusted and why, and which controlled substances are in stock right now.

  Adjustments are given their own block rather than being mixed into the
  movement list. Stock that changed without goods moving is exactly what an
  audit is about, and hiding it in a long table would be a kind of lying.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
  def viewer_events, do: ~w(period filter)

  import EstoqueOS.Coercion, only: [parse_date: 2]

  alias EstoqueOS.Reports
  alias EstoqueOSWeb.Movement

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:page_title, gettext("Audit report"))
     |> assign(:from, Date.add(today, -90))
     |> assign(:to, today)
     |> assign(:type, "")
     |> assign(:log_limit, 200)
     |> load_report()}
  end

  defp load_report(socket) do
    %{from: from, to: to, type: type} = socket.assigns

    summary = Reports.movement_summary(from, to)
    adjustments = Reports.adjustment_summary(from, to)

    socket
    |> assign(:summary, summary)
    |> assign(:adjustments, adjustments)
    |> assign(
      :log,
      Reports.transaction_log(from, to, type: type, limit: socket.assigns.log_limit)
    )
    |> assign(:controlled, Reports.controlled_stock())
    |> assign(:totals, totals(summary, adjustments))
  end

  # Derived from the tables already on screen rather than from four more
  # queries: the headline and the detail can never disagree.
  defp totals(summary, adjustments) do
    %{
      events: sum_by(summary, :transactions),
      units_in: sum_by(summary, :units_in),
      units_out: Decimal.abs(sum_by(summary, :units_out)),
      adjustments: sum_by(adjustments, :transactions)
    }
  end

  defp sum_by(rows, key) do
    Enum.reduce(rows, Decimal.new(0), fn row, acc ->
      Decimal.add(acc, to_decimal(Map.get(row, key)))
    end)
  end

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Audit report")}
        <:subtitle>
          {gettext("Everything that moved between %{from} and %{to}.",
            from: date(@from),
            to: date(@to)
          )}
        </:subtitle>
      </.header>

      <form id="period-form" phx-change="filter" class="field-row mt-4">
        <label class="fieldset">
          <span class="label">{gettext("From")}</span>
          <input type="date" name="from" value={@from} class="input input-bordered" />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("To")}</span>
          <input type="date" name="to" value={@to} class="input input-bordered" />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Movement type")}</span>
          <select name="type" class="select select-bordered">
            <option value="">{gettext("All movement types")}</option>
            <option
              :for={type <- EstoqueOS.Inventory.Transaction.types()}
              value={type}
              selected={type == @type}
            >
              {Movement.label(type)}
            </option>
          </select>
        </label>

        <div class="join">
          <button
            :for={
              {label, days} <- [
                {gettext("30 days"), 30},
                {gettext("90 days"), 90},
                {gettext("1 year"), 365}
              ]
            }
            type="button"
            phx-click="period"
            phx-value-days={days}
            class={["btn join-item", @from == Date.add(@to, -days) && "btn-active"]}
          >
            {label}
          </button>
        </div>
      </form>

      <!-- The period's size before its detail. An auditor asks "how much moved"
           long before "what moved", and the answer was buried in a table. -->
      <div class="grid grid-cols-4 gap-3 mt-6">
        <.stat label={gettext("Movements")} value={quantity(@totals.events)} />
        <.stat label={gettext("Units in")} value={quantity(@totals.units_in)} />
        <.stat label={gettext("Units out")} value={quantity(@totals.units_out)} />
        <.stat
          label={gettext("Adjustments")}
          value={quantity(@totals.adjustments)}
          hint={gettext("stock changed without goods moving")}
        />
      </div>

      <.panel title={gettext("Movements by type")}>
        <.data_table rows={@summary} row_id={&"summary-#{&1.type}"}>
          <:empty>
            <p class="opacity-80">{gettext("Nothing moved in this period.")}</p>
          </:empty>

          <:col :let={row} label={gettext("Type")} emphasis={:identity}>
            <Movement.movement_badge type={row.type} />
          </:col>
          <:col :let={row} label={gettext("Events")} align={:right} emphasis={:primary}>
            {row.transactions}
          </:col>
          <:col :let={row} label={gettext("Lines")} align={:right}>{row.lines}</:col>
          <:col :let={row} label={gettext("Units in")} align={:right}>
            {quantity(row.units_in)}
          </:col>
          <:col :let={row} label={gettext("Units out")} align={:right}>
            {quantity(row.units_out)}
          </:col>
        </.data_table>
      </.panel>

      <.panel
        title={gettext("Adjustments by reason")}
        note={gettext("Stock that changed without goods moving. Every line has a reason on record.")}
      >
        <.data_table rows={@adjustments} row_id={&"reason-#{&1.reason_code}"}>
          <:empty>
            <p class="opacity-80">{gettext("No adjustment in this period.")}</p>
          </:empty>

          <:col :let={row} label={gettext("Reason")} emphasis={:identity}>
            {Movement.reason_label(row.reason_code)}
          </:col>
          <:col :let={row} label={gettext("Events")} align={:right} emphasis={:primary}>
            {row.transactions}
          </:col>
          <:col :let={row} label={gettext("Units in")} align={:right}>
            {quantity(row.units_in)}
          </:col>
          <:col :let={row} label={gettext("Units out")} align={:right}>
            {quantity(row.units_out)}
          </:col>
        </.data_table>
      </.panel>

      <.panel
        title={gettext("Controlled substances in stock")}
        note={gettext("%{count} position(s) under Portaria 344.", count: length(@controlled))}
      >
        <.data_table rows={@controlled}>
          <:empty>
            <p class="opacity-80">{gettext("No controlled substance in stock.")}</p>
          </:empty>

          <:col :let={row} label={gettext("Product")} emphasis={:identity}>{row.product}</:col>
          <:col :let={row} label={gettext("Lot")}>{row.lot_number || gettext("unknown")}</:col>
          <:col :let={row} label={gettext("Expiry")}>{date(row.expires_on)}</:col>
          <:col :let={row} label={gettext("Location")}>{row.location}</:col>
          <:col :let={row} label={gettext("Box")}>{row.box || "—"}</:col>
          <:col :let={row} label={gettext("Quantity")} align={:right} emphasis={:primary}>
            {quantity(row.quantity)}
          </:col>
        </.data_table>
      </.panel>

      <.panel
        title={gettext("Movement log")}
        note={
          length(@log) >= @log_limit &&
            gettext("Showing the %{count} most recent movements of this period.",
              count: @log_limit
            )
        }
      >
        <.data_table rows={@log} row_id={&"transaction-#{&1.transaction.id}"}>
          <:empty>
            <p class="opacity-80">{gettext("Nothing to show.")}</p>
          </:empty>

          <:col :let={row} label={gettext("When")} emphasis={:identity}>
            {datetime(row.transaction.occurred_at)}
          </:col>

          <:col :let={row} label={gettext("Type")}>
            <Movement.movement_badge type={row.transaction.type} />
            <span :if={row.transaction.reason_code} class="badge badge-warning badge-sm">
              {Movement.reason_label(row.transaction.reason_code)}
            </span>
          </:col>

          <:col :let={row} label={gettext("Route")}>{Movement.route(row.transaction) || "—"}</:col>
          <:col :let={row} label={gettext("Document")}>
            {Movement.document(row.transaction) || "—"}
          </:col>
          <:col :let={row} label={gettext("Who")} emphasis={:muted}>
            {(row.transaction.user && row.transaction.user.email) || "—"}
          </:col>
          <:col :let={row} label={gettext("Lines")} align={:right}>{row.lines}</:col>
          <:col :let={row} label={gettext("Units")} align={:right} emphasis={:primary}>
            {quantity(row.units)}
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("period", %{"days" => days}, socket) do
    to = Date.utc_today()
    from = Date.add(to, -String.to_integer(days))

    {:noreply, socket |> assign(:from, from) |> assign(:to, to) |> load_report()}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:from, parse_date(params["from"], socket.assigns.from))
     |> assign(:to, parse_date(params["to"], socket.assigns.to))
     |> assign(:type, params["type"] || "")
     |> load_report()}
  end
end
