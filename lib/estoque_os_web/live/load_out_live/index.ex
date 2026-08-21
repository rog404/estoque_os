defmodule EstoqueOSWeb.LoadOutLive.Index do
  @moduledoc """
  The load-out: sending a mission's supplies out of the warehouse.

  Everything starts selected, because in practice the whole stock leaves and
  what stays behind is the exception. Taking something out of the load is one
  click; building the load item by item would be a week of work.
  """

  use EstoqueOSWeb, :live_view

  import EstoqueOS.Coercion

  alias EstoqueOS.Outbound

  alias EstoqueOS.Inventory.Locations

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Choosing where the load goes and where it comes from only recalculates the
  plan. `send` is the movement.
  """
  def viewer_events, do: ~w(route)

  @impl true
  def mount(_params, _session, socket) do
    locations = Locations.list_locations()
    source = Locations.default_location() || List.first(locations)

    {:ok,
     socket
     |> assign(:page_title, gettext("Load-out"))
     |> assign(:locations, locations)
     |> assign(:source_id, source && source.id)
     |> assign(:destination_id, default_destination(locations, source))
     |> assign(:result, nil)
     |> load_plan()}
  end

  defp default_destination(locations, source) do
    locations
    |> Enum.reject(&(source && &1.id == source.id))
    |> Enum.sort_by(&destination_rank(&1.kind))
    |> List.first()
    |> case do
      nil -> nil
      location -> location.id
    end
  end

  defp destination_rank("mission_site"), do: 0
  defp destination_rank("transit"), do: 1
  defp destination_rank(_kind), do: 2

  defp load_plan(socket) do
    plan =
      case socket.assigns.source_id do
        nil -> %{boxes: [], loose: []}
        id -> Outbound.plan(id)
      end

    socket
    |> assign(:plan, plan)
    |> assign(:selected_boxes, MapSet.new(Enum.map(plan.boxes, & &1.box.id)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Load-out")}
        <:subtitle>
          {gettext("Everything is selected by default — uncheck what stays behind.")}
        </:subtitle>
      </.header>

      <div :if={@result} class="alert alert-success mt-4">
        {gettext("Load sent: %{boxes} box(es) and %{lines} loose line(s).",
          boxes: @result.boxes_moved,
          lines: @result.loose_lines
        )}
      </div>

      <form id="route-form" phx-change="route" class="field-row mt-4">
        <label class="fieldset">
          <span class="label">{gettext("From")}</span>
          <select name="source_id" class="select select-bordered">
            <option
              :for={location <- @locations}
              value={location.id}
              selected={location.id == @source_id}
            >
              {location.name}
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="label">{gettext("To")}</span>
          <select name="destination_id" class="select select-bordered">
            <option
              :for={location <- @locations}
              value={location.id}
              selected={location.id == @destination_id}
              disabled={location.id == @source_id}
            >
              {location.name}
            </option>
          </select>
        </label>
      </form>

      <p :if={@plan.boxes == [] and @plan.loose == []} class="mt-8 opacity-70">
        {gettext("There is nothing to send from here.")}
      </p>

      <form :if={@plan.boxes != []} id="load-form" phx-submit="send" class="mt-6">
        <section>
          <h2 class="font-semibold">{gettext("Boxes")}</h2>
          <p class="text-sm opacity-70">
            {gettext("A box travels whole and is not recounted.")}
          </p>

          <div class="mt-2">
            <.panel title={gettext("Boxes to send")} flush>
              <.data_table rows={@plan.boxes} row_id={&"box-#{&1.box.id}"}>
                <:col :let={row} label={gettext("Box")} emphasis={:identity}>
                  {row.box.code}
                </:col>
                <:col :let={row} label={gettext("Send")} field={:inline}>
                  <input
                    type="checkbox"
                    name="box_ids[]"
                    value={row.box.id}
                    checked={MapSet.member?(@selected_boxes, row.box.id)}
                    class="checkbox"
                    aria-label={gettext("Send box %{code}", code: row.box.code)}
                  />
                </:col>
                <:col :let={row} label={gettext("Presumed contents")} align={:right}>
                  {quantity(row.quantity)}
                  <span class="text-xs opacity-60">
                    {gettext("in %{count} position(s)", count: row.positions)}
                  </span>
                </:col>
              </.data_table>
            </.panel>
          </div>
        </section>

        <div class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-6">
          <.commit_action
            id="confirm-load-out"
            form="load-form"
            label={gettext("Send load")}
            title={gettext("Send this load?")}
            confirm_label={gettext("Send load")}
          >
            <:consequence>
              <p>
                {gettext("%{boxes} box(es) and %{lines} loose line(s) leave %{from} for %{to}.",
                  boxes: MapSet.size(@selected_boxes),
                  lines: length(@plan.loose),
                  from: location_name(@locations, @source_id),
                  to: location_name(@locations, @destination_id)
                )}
              </p>
              <p class="text-sm">
                {gettext("Boxes travel whole and are not recounted.")}
              </p>
            </:consequence>
          </.commit_action>
          <p class="text-sm opacity-70">
            {gettext("The whole shipment is recorded as one event.")}
          </p>
        </div>
      </form>

      <!-- Listed, never offered. Goods that leave without a box have nothing
           identifying them at the mission and nothing bringing them back — in
           practice already written off — so the screen points at the conference
           instead of taking the order. -->
      <section
        :if={@plan.loose != []}
        class="alert alert-warning flex-col items-start gap-2 mt-6"
      >
        <h2 class="font-semibold">
          {gettext("%{count} position(s) are not in a box and cannot travel.",
            count: length(@plan.loose)
          )}
        </h2>
        <p class="text-sm">
          {gettext(
            "Box them in the receiving conference first. Anything leaving loose has nothing to identify it at the mission and nothing to bring it back."
          )}
        </p>

        <ul class="w-full text-sm">
          <li :for={row <- Enum.take(@plan.loose, 8)} class="flex justify-between gap-4">
            <span>
              {row.product}
              <.status :if={row.controlled} kind={:controlled} />
            </span>
            <span class="opacity-70">{quantity(row.quantity)}</span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("route", params, socket) do
    source_id = to_id(params["source_id"])
    source_changed? = source_id != socket.assigns.source_id

    socket =
      socket
      |> assign(:source_id, source_id)
      |> assign(:destination_id, to_id(params["destination_id"]))

    {:noreply, if(source_changed?, do: load_plan(socket), else: socket)}
  end

  def handle_event("send", params, socket) do
    picks =
      params
      |> Map.get("picks", %{})
      |> Enum.reject(fn {_lot_id, value} -> String.trim(value) in ["", "0"] end)
      |> Map.new()

    attrs = %{
      source_location_id: socket.assigns.source_id,
      destination_location_id: socket.assigns.destination_id,
      box_ids: Map.get(params, "box_ids", []),
      picks: picks,
      user_id: socket.assigns.current_scope.user.id
    }

    case Outbound.load_out(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:result, Map.put(result, :loose_lines, map_size(picks)))
         |> put_flash(:info, gettext("Load sent."))
         |> load_plan()}

      {:error, {:negative_stock, _positions}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Some line asks for more than there is here. Check the quantities.")
         )}

      {:error, :nothing_to_send} ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one box or line to send."))}

      {:error, :same_location} ->
        {:noreply,
         put_flash(socket, :error, gettext("Choose a destination other than the origin."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The load could not be sent."))}
    end
  end

  defp location_name(locations, id) do
    case Enum.find(locations, &(&1.id == id)) do
      nil -> "—"
      location -> location.name
    end
  end
end
