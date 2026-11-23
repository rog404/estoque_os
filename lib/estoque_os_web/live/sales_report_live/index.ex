defmodule EstoqueOSWeb.SalesReportLive.Index do
  @moduledoc """
  What was sold in a period, and what it left behind. A sale is a `manual_out`
  to the `sale` destination in the same ledger; there is no second book.

  Revenue, cost and margin, plus how many lines had no cost: donated stock
  carries none, so without that count margin would overstate by the donation.
  """

  use EstoqueOSWeb, :live_view

  # Events a viewer may send; everything else is refused. Reporting only.
  def viewer_events, do: ~w(period filter)

  import EstoqueOS.Coercion, only: [blank_to_nil: 1, parse_date: 2]

  alias EstoqueOS.Reports
  alias EstoqueOSWeb.StockLive

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:page_title, gettext("Sales"))
     |> assign(:from, Date.add(today, -90))
     |> assign(:to, today)
     |> assign(:segment, segment(socket, "marketing"))
     |> load_report()}
  end

  # Marketing is the default view, but a sold surgical item must not be hidden:
  # either stock is a filter away.
  defp segment(_socket, asked), do: asked

  defp load_report(socket) do
    %{from: from, to: to, segment: segment} = socket.assigns

    rows = Reports.sales(from, to, segment: blank_to_nil(segment))

    socket
    |> assign(:rows, rows)
    |> assign(:totals, Reports.sales_totals(rows))
    |> assign(:places, Reports.sales_by_place(from, to, segment: blank_to_nil(segment)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Sales")}
        <:subtitle>
          {gettext("What was sold between %{from} and %{to}.", from: date(@from), to: date(@to))}
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
          <span class="label">{gettext("Stock")}</span>
          <select name="segment" class="select select-bordered">
            <option value="marketing" selected={@segment == "marketing"}>
              {StockLive.Index.segment_label("marketing")}
            </option>
            <option value="medical" selected={@segment == "medical"}>
              {StockLive.Index.segment_label("medical")}
            </option>
            <option value="" selected={@segment in [nil, ""]}>{gettext("Every stock")}</option>
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

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mt-6">
        <.stat label={gettext("Units sold")} value={quantity(@totals.quantity)} />
        <%!-- `money` on all three, or the headline figures stay visible while the table is masked. --%>
        <.stat label={gettext("Revenue")} value={money(@totals.revenue)} money />
        <.stat
          label={gettext("Cost of what was sold")}
          value={money(@totals.cost)}
          money
          hint={gettext("what the ONG paid for it")}
        />
        <.stat
          label={gettext("Margin")}
          value={money(@totals.margin)}
          money
          hint={
            if @totals.unpriced > 0,
              do: gettext("%{count} line(s) came from stock with no cost", count: @totals.unpriced),
              else: gettext("revenue minus cost")
          }
        />
      </div>

      <%!-- The place comes from the entry, not the movement: a sale does not travel, so it has no source location. --%>
      <.panel :if={@places != []} title={gettext("By place")} flush class="mb-6">
        <.data_table rows={@places} row_id={&"place-#{&1.location_id}"}>
          <:col :let={row} label={gettext("Place")} emphasis={:identity}>
            {row.location}
            <p class="text-sm text-base-content/80">{place_kind(row.kind)}</p>
          </:col>

          <:col :let={row} label={gettext("Quantity")} align={:right} group>
            {quantity(row.quantity)}
          </:col>

          <:col :let={row} label={gettext("Revenue")} align={:right} emphasis={:primary}>
            <.amount value={money(row.revenue)} />
          </:col>

          <:col :let={row} label={gettext("Cost")} align={:right} emphasis={:muted}>
            <.amount value={money(row.cost)} />
          </:col>

          <:col :let={row} label={gettext("Margin")} align={:right}>
            <.amount value={money(row.margin)} />
            <%!-- Always rendered, `invisible` when empty, so rows keep their height. --%>
            <p class={["text-xs text-warning", row.unpriced == 0 && "invisible"]}>
              {gettext("%{count} without cost", count: row.unpriced)}
            </p>
          </:col>
        </.data_table>
      </.panel>

      <.panel title={gettext("By product")} flush>
        <.data_table rows={@rows} row_id={&"sale-#{&1.product_id}"}>
          <:empty>
            <.empty
              title={gettext("Nothing was sold in this period.")}
              note={
                gettext(
                  "A sale is a write-off sent to \"Venda\", with the price it went out for on each line."
                )
              }
            />
          </:empty>

          <:col :let={row} label={gettext("Product")} emphasis={:identity}>
            <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
              {row.product}
            </.link>
            <p class="text-sm text-base-content/80">{row.unit}</p>
          </:col>

          <:col :let={row} label={gettext("Quantity")} align={:right} group>
            {quantity(row.quantity)}
          </:col>

          <:col :let={row} label={gettext("Revenue")} align={:right} emphasis={:primary}>
            <.amount value={money(row.revenue)} />
          </:col>

          <:col :let={row} label={gettext("Cost")} align={:right} emphasis={:muted}>
            <.amount value={money(row.cost)} />
          </:col>

          <:col :let={row} label={gettext("Margin")} align={:right}>
            <.amount value={money(Decimal.sub(row.revenue, row.cost))} />
            <%!-- Always rendered, `invisible` when empty, so rows keep their height. --%>
            <p class={["text-xs text-warning", row.unpriced == 0 && "invisible"]}>
              {gettext("%{count} without cost", count: row.unpriced)}
            </p>
          </:col>

          <:foot span={2}>{gettext("%{count} product(s)", count: length(@rows))}</:foot>
          <:foot align={:right}><.amount value={money(@totals.revenue)} /></:foot>
          <:foot align={:right}><.amount value={money(@totals.cost)} /></:foot>
          <:foot align={:right}><.amount value={money(@totals.margin)} /></:foot>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  # "Other" covers the office counter and fair stand, hence "elsewhere".
  defp place_kind("mission_site"), do: gettext("mission or event")
  defp place_kind("warehouse"), do: gettext("warehouse")
  defp place_kind("transit"), do: gettext("in transit")
  defp place_kind(_other), do: gettext("elsewhere")

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:from, parse_date(params["from"], socket.assigns.from))
     |> assign(:to, parse_date(params["to"], socket.assigns.to))
     |> assign(:segment, segment(socket, params["segment"] || socket.assigns.segment))
     |> load_report()}
  end

  def handle_event("period", %{"days" => days}, socket) do
    days = String.to_integer(days)

    {:noreply,
     socket
     |> assign(:from, Date.add(socket.assigns.to, -days))
     |> load_report()}
  end
end
