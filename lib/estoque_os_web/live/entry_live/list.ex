defmodule EstoqueOSWeb.EntryLive.List do
  @moduledoc """
  Everything that came in by hand, newest first.

  The mirror of the write-off list, and it exists for the same reason: goods
  taken in at the door are filed under the same ledger types as an invoice —
  `purchase_in` for something bought without a nota, `donation_in` for something
  given — so they were showing up in the log wearing the invoice's name, and
  whoever went looking for a manual entry ended up in the invoice list with
  nothing to find.

  What separates the two is the document, and an entry made at the door has
  none. That is the filter, and it is a fact on the record rather than a second
  transaction type invented for the screen.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
  def viewer_events, do: ~w(filter)

  import EstoqueOS.Coercion, only: [parse_date: 2]

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Reports
  alias EstoqueOSWeb.Movement

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:page_title, gettext("Manual entries"))
     |> assign(:from, Date.add(today, -90))
     |> assign(:to, today)
     |> assign(:origin, "")
     |> assign(:segment, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:origin, params["origin"] || "")
     |> assign(:segment, Scope.segment(socket.assigns.current_scope, params["segment"]))
     |> load_entries()}
  end

  defp load_entries(socket) do
    %{from: from, to: to, origin: origin, segment: segment} = socket.assigns

    assign(
      socket,
      :rows,
      Reports.transaction_log(from, to,
        type: types_for(origin),
        without_invoice: true,
        segment: segment,
        limit: 200
      )
    )
  end

  # Bought or given: the two ways goods arrive without a nota, and the one
  # question somebody filters this list by.
  defp types_for("purchase"), do: ["purchase_in"]
  defp types_for("donation"), do: ["donation_in"]
  defp types_for(_all), do: ["purchase_in", "donation_in"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Manual entries")}
        <:subtitle>
          {gettext("Goods taken in by hand between %{from} and %{to}.",
            from: date(@from),
            to: date(@to)
          )}
        </:subtitle>
        <:actions>
          <.button navigate={~p"/entry"}>{gettext("New entry")}</.button>
        </:actions>
      </.header>

      <form id="entries-filter" phx-change="filter" class="field-row mt-4">
        <label class="fieldset">
          <span class="label">{gettext("From")}</span>
          <input type="date" name="from" value={@from} class="input input-bordered" />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("To")}</span>
          <input type="date" name="to" value={@to} class="input input-bordered" />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Where it came from")}</span>
          <select name="origin" class="select select-bordered">
            <option value="">{gettext("Bought and donated")}</option>
            <option value="purchase" selected={@origin == "purchase"}>{gettext("Bought")}</option>
            <option value="donation" selected={@origin == "donation"}>{gettext("Donated")}</option>
          </select>
        </label>
      </form>

      <.panel flush>
        <.data_table rows={@rows} row_id={&"entry-#{&1.transaction.id}"}>
          <:empty>
            <.empty
              title={gettext("Nothing came in by hand in this period.")}
              note={gettext("Try a wider period. Invoices are in Notas fiscais, not here.")}
            />
          </:empty>

          <:col :let={row} label={gettext("When")} emphasis={:identity}>
            {datetime(row.transaction.occurred_at)}
          </:col>

          <:col :let={row} label={gettext("Kind")}>
            <Movement.movement_badge movement={row.transaction} />
          </:col>

          <:col :let={row} label={gettext("What came in")} emphasis={:muted}>
            {items_label(row.transaction)}
          </:col>

          <:col :let={row} label={gettext("Where")} emphasis={:muted}>
            {where_label(row.transaction)}
          </:col>

          <:col :let={row} label={gettext("Who")} emphasis={:muted}>
            {(row.transaction.user && row.transaction.user.email) || "—"}
          </:col>

          <:col :let={row} label={gettext("Units")} align={:right} emphasis={:primary}>
            {quantity(row.units)}
          </:col>

          <:col :let={row} :if={@sees_money?} label={gettext("Value")} align={:right}>
            <.amount value={money(row.value)} />
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  # The products are the point of the row; the lots are not, at this altitude.
  defp items_label(transaction) do
    names =
      transaction.entries
      |> Enum.map(& &1.lot.product.name)
      |> Enum.uniq()

    case names do
      [] ->
        "—"

      [one] ->
        one

      [first | rest] ->
        gettext("%{product} and %{count} more", product: first, count: length(rest))
    end
  end

  # Which shelf it landed on, which is the question somebody reading this list
  # is usually about to walk over and check.
  defp where_label(transaction) do
    case transaction.entries do
      [] -> "—"
      [entry | _rest] -> (entry.location && entry.location.name) || "—"
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:from, parse_date(params["from"], socket.assigns.from))
     |> assign(:to, parse_date(params["to"], socket.assigns.to))
     |> assign(:origin, params["origin"] || "")
     |> load_entries()}
  end
end
