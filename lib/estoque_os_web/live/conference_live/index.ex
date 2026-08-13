defmodule EstoqueOSWeb.ConferenceLive.Index do
  @moduledoc """
  What is waiting to be checked.

  The screen the operator starts their day from. Until it existed, the only door
  into a conference was the invoice screen — and an invoice is a document of
  prices, so it sits behind the money gate that the logistics role is on the
  wrong side of. The person whose entire job this is could not find the work.

  Nothing here carries an amount. That is not decoration: it is what lets this
  screen live in Operação at all.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Receiving
  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Conference"))
     |> load_pending()}
  end

  defp load_pending(socket), do: assign(socket, :rows, Receiving.list_pending())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Conference")}
        <:subtitle>
          {gettext("Deliveries waiting to be checked against what was ordered.")}
        </:subtitle>
      </.header>

      <.panel title={gettext("Waiting")} flush>
        <.data_table rows={@rows} row_id={&"pending-#{&1.invoice.id}"}>
          <:empty>
            <.empty
              icon="hero-check-circle"
              title={gettext("Nothing waiting to be checked.")}
              note={
                gettext(
                  "Every delivery that arrived has been conferred. A new one shows up here as soon as its invoice is posted to stock."
                )
              }
            />
          </:empty>

          <:col :let={row} label={gettext("Delivery")} emphasis={:identity}>
            <p class="font-medium">{row.invoice.supplier.legal_name}</p>
            <p class="text-xs opacity-60">
              {gettext("NF %{number} · %{date}",
                number: row.invoice.number,
                date: date(row.invoice.issued_on)
              )}
            </p>
          </:col>

          <:col :let={row} label={gettext("Round")}>
            {gettext("Round %{round}", round: row.round)}
            <p :if={row.closed_rounds > 0} class="text-xs opacity-60">
              {gettext("%{count} already closed", count: row.closed_rounds)}
            </p>
          </:col>

          <:col :let={row} label={gettext("Progress")} align={:right}>
            <span :if={row.receipt} class="tabular-nums">
              {gettext("%{counted} of %{lines}", counted: row.counted, lines: row.lines)}
            </span>
            <.status :if={is_nil(row.receipt)} kind={:pending} detail={gettext("not started")} />
          </:col>

          <:col :let={row} label={gettext("Actions")} hide_label_on_card={true} field={:inline} group>
            <div class="flex justify-end">
              <.link
                :if={row.receipt}
                navigate={~p"/receipts/#{row.receipt}"}
                class="btn btn-sm btn-primary"
              >
                {gettext("Continue counting")}
              </.link>
              <!-- No `@writable?` guard: this route already requires an
                   operator, so the question is settled before the page
                   renders. -->
              <button
                :if={is_nil(row.receipt)}
                phx-click="start"
                phx-value-invoice={row.invoice.id}
                class="btn btn-sm btn-primary"
                phx-disable-with={gettext("Opening...")}
              >
                {gettext("Start counting")}
              </button>
            </div>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("start", %{"invoice" => invoice_id}, socket) do
    invoice = EstoqueOS.Invoices.get_invoice!(invoice_id)

    attrs = %{
      location_id: default_location_id(),
      user_id: socket.assigns.current_scope.user.id
    }

    case Receiving.start_receipt(invoice, attrs) do
      {:ok, receipt} ->
        {:noreply, push_navigate(socket, to: ~p"/receipts/#{receipt}")}

      {:error, :receipt_already_open} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("There is already an open conference."))
         |> load_pending()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The conference could not be started."))}
    end
  end

  defp default_location_id do
    case Locations.default_location() do
      nil -> nil
      location -> location.id
    end
  end
end
