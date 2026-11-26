defmodule EstoqueOSWeb.IssueLive.List do
  @moduledoc """
  Everything that left by hand, newest first. A donation is a manual issue whose
  destination is a hospital, so it lives here; filter by destination to see what
  was given away. The donation certificate is printed from here, per movement.
  """

  use EstoqueOSWeb, :live_view

  # Events a viewer may send; everything else is refused. Reporting only.
  def viewer_events, do: ~w(filter)

  alias EstoqueOS.Inventory.Transaction

  import EstoqueOSWeb.Movement, only: [destination_label: 1]
  alias EstoqueOS.Accounts.Scope
  import EstoqueOS.Coercion, only: [parse_date: 2]

  alias EstoqueOS.Reports
  alias EstoqueOSWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(:page_title, gettext("Manual issues"))
     |> assign(:from, Date.add(today, -90))
     |> assign(:to, today)
     |> assign(:destination, "")
     |> assign(:segment, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:destination, params["destination"] || "")
     |> assign(:segment, segment(socket, params["segment"]))
     |> load_issues()}
  end

  # A movement belongs to a segment through what it moved; the role wins over the address.
  defp segment(socket, asked), do: Scope.segment(socket.assigns.current_scope, asked)

  defp load_issues(socket) do
    %{from: from, to: to, destination: destination, segment: segment} = socket.assigns

    assign(
      socket,
      :rows,
      Reports.transaction_log(from, to,
        type: "manual_out",
        destination: destination,
        segment: segment,
        limit: 200
      )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Manual issues")}
        <:actions>
          <.button navigate={~p"/issue"}>{gettext("New issue")}</.button>
        </:actions>
      </.header>

      <form id="issues-filter" phx-change="filter" class="field-row mt-4">
        <label class="fieldset">
          <span class="label">{gettext("From")}</span>
          <input type="date" name="from" value={@from} class="input input-bordered" />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("To")}</span>
          <input type="date" name="to" value={@to} class="input input-bordered" />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Where to")}</span>
          <select name="destination" class="select select-bordered">
            <option value="">{gettext("All destinations")}</option>
            <option
              :for={destination <- Transaction.destinations()}
              value={destination}
              selected={destination == @destination}
            >
              {destination_label(destination)}
            </option>
          </select>
        </label>
      </form>

      <.panel flush>
        <.data_table rows={@rows} row_id={&"issue-#{&1.transaction.id}"}>
          <:empty>
            <.empty
              title={gettext("Nothing left by hand in this period.")}
              note={
                gettext("Try a wider period. Load-outs and mission returns are not counted here.")
              }
            />
          </:empty>

          <:col :let={row} label={gettext("When")} emphasis={:identity}>
            {datetime(row.transaction.occurred_at)}
          </:col>

          <%!-- Plain text, not a badge: a badge does not wrap, and a destination is a value, not a `status/1` state. --%>
          <:col :let={row} label={gettext("Where to")}>
            <span :if={row.transaction.destination}>
              {destination_label(row.transaction.destination)}
            </span>
            <span :if={is_nil(row.transaction.destination)} class="opacity-60">
              {gettext("not stated")}
            </span>
          </:col>

          <:col :let={row} label={gettext("Recipient")}>
            {row.transaction.recipient_name || "—"}
            <p :if={row.transaction.recipient_tax_id} class="text-xs opacity-60">
              {format_tax_id(row.transaction.recipient_tax_id)}
            </p>
          </:col>

          <:col :let={row} label={gettext("What left")} emphasis={:muted}>
            {items_label(row.transaction)}
          </:col>

          <:col :let={row} label={gettext("Who")} emphasis={:muted}>
            {(row.transaction.user && row.transaction.user.email) || "—"}
          </:col>

          <:col :let={row} label={gettext("Units")} align={:right} emphasis={:primary}>
            {quantity(Decimal.abs(row.units))}
          </:col>

          <:col :let={row} label={gettext("Certificate")} hide_label_on_card={true}>
            <.link
              :if={
                row.transaction.destination == "donation" and UserAuth.role_may_write?(@current_scope)
              }
              href={~p"/issues/#{row.transaction.id}/termo/doacao"}
              target="_blank"
              class="btn-sm"
            >
              <.icon name="hero-document-text" class="size-4" />
              {gettext("Certificate")}
            </.link>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp items_label(transaction) do
    names =
      transaction.entries
      |> Enum.map(& &1.lot.product.name)
      |> Enum.uniq()

    case names do
      [] -> "—"
      [one] -> one
      [one | rest] -> gettext("%{product} +%{count}", product: one, count: length(rest))
    end
  end

  defp format_tax_id(<<a::binary-2, b::binary-3, c::binary-3, d::binary-4, e::binary-2>>) do
    "#{a}.#{b}.#{c}/#{d}-#{e}"
  end

  defp format_tax_id(other), do: other

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:from, parse_date(params["from"], socket.assigns.from))
     |> assign(:to, parse_date(params["to"], socket.assigns.to))
     |> assign(:destination, params["destination"] || "")
     |> assign(:segment, segment(socket, params["segment"] || socket.assigns.segment))
     |> load_issues()}
  end
end
