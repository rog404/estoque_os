defmodule EstoqueOSWeb.SalesReportLive.Index do
  @moduledoc """
  What was sold in a period, and what it left behind.

  The marketing stock is the one that goes out with a price on it, so this is
  the report that belongs to whoever looks after it — and it reads the same
  ledger as everything else. A sale is a `manual_out` to the `sale` destination;
  there is no second book.

  Three numbers, in the order they are asked: what came in, what it had cost,
  and the difference. The fourth — how many lines had no cost at all — is what
  says whether the third can be believed, because stock that arrived as a
  donation carries no cost and reporting it as pure margin would be a lie the
  size of the donation.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
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

  # Marketing is the default view because marketing is the stock that is sold —
  # and a surgical item that was sold is exactly the thing a report should not
  # hide, so either stock is a filter away for anybody.
  defp segment(_socket, asked), do: asked

  defp load_report(socket) do
    %{from: from, to: to, segment: segment} = socket.assigns

    rows = Reports.sales(from, to, segment: blank_to_nil(segment))

    socket
    |> assign(:rows, rows)
    |> assign(:totals, Reports.sales_totals(rows))
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
        <!-- Absent for a role with one stock, like every other segment picker:
             a question with one answer is not a question. -->
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
        <!-- `money` on all three, so they follow the eye in the bar like every
             other amount. Without it the headline figures stayed on screen
             while the table below them was masked, which is the leak that
             hiding amounts exists to prevent. -->
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
            <!-- Always rendered, `invisible` when there is nothing to say: a
                 note that appears only on some rows changes their height, and
                 this table is read down a column. -->
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
