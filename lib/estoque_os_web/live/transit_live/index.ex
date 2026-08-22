defmodule EstoqueOSWeb.TransitLive.Index do
  @moduledoc """
  What is on the road right now, and who has it.

  The question this exists for is one somebody asks on the phone: *quem está com
  a carga?* Before the shipment was a record, the ledger could answer only that
  some quantity sat at a location called Trânsito — one bucket, so two loads
  travelling at once were indistinguishable, and nothing said with whom, since
  when, or expected where.

  Oldest first, deliberately. A load that left three weeks ago is the one worth a
  call; sorting by newest would bury it under this morning's.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
  def viewer_events, do: ~w(filter)

  alias EstoqueOS.Catalog
  alias EstoqueOS.Outbound

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("In transit"))
     |> assign(:carriers, Catalog.list_carriers())
     |> assign(:carrier_id, nil)
     |> load_shipments()}
  end

  defp load_shipments(socket) do
    rows = Outbound.open_shipments(carrier_id: socket.assigns.carrier_id)

    socket
    |> assign(:rows, rows)
    |> assign(:late, Enum.count(rows, & &1.late?))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("In transit")}
        <:subtitle>
          {gettext("%{count} load(s) still out there", count: length(@rows))}
          <span :if={@late > 0}>
            · {gettext("%{count} past the expected date", count: @late)}
          </span>
        </:subtitle>
      </.header>

      <form id="transit-filter" phx-change="filter" class="field-row mt-4">
        <label class="fieldset">
          <span class="label">{gettext("Carrier")}</span>
          <select name="carrier_id" class="select select-bordered">
            <option value="">{gettext("Every carrier")}</option>
            <option
              :for={carrier <- @carriers}
              value={carrier.id}
              selected={carrier.id == @carrier_id}
            >
              {Catalog.Carrier.name(carrier)}
            </option>
          </select>
        </label>
      </form>

      <.panel title={gettext("Loads on the road")} flush>
        <.data_table rows={@rows} row_id={&"shipment-#{&1.shipment.id}"}>
          <:empty>
            <.empty
              icon="hero-check-circle"
              title={gettext("Nothing is on the road.")}
              note={gettext("Every load that left has been received.")}
            />
          </:empty>

          <:col :let={row} label={gettext("Route")} emphasis={:identity}>
            {row.shipment.from_location.name} → {row.shipment.to_location.name}
            <p :if={row.shipment.mission} class="text-sm text-base-content/80">
              {row.shipment.mission.name}
            </p>
          </:col>

          <:col :let={row} label={gettext("Carrier")}>
            <span :if={row.shipment.carrier}>{Catalog.Carrier.name(row.shipment.carrier)}</span>
            <!-- Said out loud rather than left blank: a load nobody was hired to
                 carry is a normal thing here, and an empty cell reads as missing
                 data. -->
            <span :if={is_nil(row.shipment.carrier)} class="text-base-content/70">
              {gettext("carried by the team")}
            </span>
            <p :if={row.shipment.waybill} class="text-sm text-base-content/80">
              {row.shipment.waybill}
            </p>
          </:col>

          <:col :let={row} label={gettext("Left")}>
            {date(row.shipment.shipped_on)}
            <p class="text-sm text-base-content/80">
              {gettext("%{count} day(s) out", count: row.days_out)}
            </p>
          </:col>

          <!-- Where the load is, which is not the same question as where it is
               going. With a carrier it sits in transit until somebody at the
               other end says it landed; driven by the team, leaving and being
               there were one act and there is nothing to confirm. -->
          <:col :let={row} label={gettext("Where it is")}>
            <span :if={row.in_transit?} class="badge badge-warning badge-sm">
              {gettext("on the road")}
            </span>
            <span :if={not row.in_transit?} class="badge is-quiet dot-success">
              {gettext("delivered")}
            </span>

            <!-- Always rendered, hidden when it does not apply: a button that
                 appears on some rows changes their height, and a row that grows
                 when it is confirmed sends the next tap to the wrong load. -->
            <div class={["mt-1", not row.in_transit? && "invisible"]}>
              <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
                <button
                  type="button"
                  phx-click="arrive"
                  phx-value-id={row.shipment.id}
                  class="btn btn-xs"
                  phx-disable-with={gettext("Recording...")}
                >
                  {gettext("It arrived")}
                </button>
              </.write_gate>
            </div>
          </:col>

          <!-- The paper the carrier asks for, from the load it is about. Always
               rendered so the row keeps its height, and only a writer gets it:
               filling one in is an act, not a reading. -->
          <:col :let={row} label={gettext("Declaration")}>
            <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
              <.link navigate={~p"/shipments/#{row.shipment.id}/declaracao"} class="btn btn-xs">
                {gettext("Declaration")}
              </.link>
            </.write_gate>
          </:col>

          <:col :let={row} label={gettext("Expected")} group>
            <span class={row.late? && "text-error font-medium"}>
              {date(row.shipment.expected_arrival)}
            </span>
            <!-- Always rendered, hidden when it does not apply: a warning that
                 appears on some rows changes their height, and this table is
                 read down a column. -->
            <p class={["text-sm text-error", not row.late? && "invisible"]}>
              {gettext("overdue")}
            </p>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("arrive", %{"id" => id}, socket) do
    shipment = Outbound.get_shipment!(id)

    case Outbound.arrive_shipment(shipment, user_id: socket.assigns.current_scope.user.id) do
      {:ok, %{shipment: arrived}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Load delivered at %{place}.", place: arrived.to_location.name)
         )
         |> load_shipments()}

      {:error, :nothing_in_transit} ->
        {:noreply,
         put_flash(socket, :error, gettext("This load has nothing sitting in transit."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That arrival could not be recorded."))}
    end
  end

  def handle_event("filter", %{"carrier_id" => carrier_id}, socket) do
    {:noreply,
     socket
     |> assign(:carrier_id, parse_id(carrier_id))
     |> load_shipments()}
  end

  defp parse_id(""), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end
end
