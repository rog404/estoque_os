defmodule EstoqueOSWeb.IssueLive.List do
  @moduledoc """
  Everything that left by hand, newest first.

  This screen is what replaced the separate donations module: a donation is a
  manual issue whose destination happens to be a hospital, so it belongs in the
  same list as every other write-off — and filtering that list by destination is
  how the operation answers "what did we give away", which the old module could
  never do for anything but itself.

  The donation certificate is printed from here, per movement.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
  def viewer_events, do: ~w(filter)

  alias EstoqueOS.Inventory.Transaction

  # One copy of these, in `EstoqueOSWeb.Movement`. This screen and the list of
  # write-offs each had their own, which is how a new destination gets a label
  # on one screen and its raw key on the other.
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

  # A movement belongs to a segment through what it moved. The marketing role
  # gets theirs whatever the address says; anyone else may ask for one.
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
        <:subtitle>
          {gettext("Goods that left by hand between %{from} and %{to}.",
            from: date(@from),
            to: date(@to)
          )}
        </:subtitle>
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

      <!-- The page header already says it; see box_live/index.ex. -->
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

          <!-- Plain text, not a badge. A daisyUI badge does not wrap, so a
               two-word destination — "Sala de cirurgia", "Pré e pós" — ran out
               of its own grey fill and tore the background. And a destination is
               a value, not one of the states `status/1` owns: it names where the
               goods went, not whether anything is wrong. -->
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
              :if={row.transaction.destination == "donation" and UserAuth.operator?(@current_scope)}
              href={~p"/issues/#{row.transaction.id}/termo/doacao"}
              target="_blank"
              class="btn btn-ghost btn-sm"
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

  # The products are the point of the row; the lots are not, at this altitude.
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
