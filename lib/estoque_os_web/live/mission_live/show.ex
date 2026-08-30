defmodule EstoqueOSWeb.MissionLive.Show do
  @moduledoc """
  What one trip did to the stock.

  Four columns, and they are four different questions. Returned is not consumed:
  the goods came back. Donated is not consumed either — they still exist, they
  just belong to the hospital now, and a certificate was signed for them. Rolling
  the two into "gone" is exactly the reporting that makes a coordinator unable to
  answer an auditor.

  `unaccounted` is what the ledger cannot place. It is shown even when the answer
  is uncomfortable, because a mission report that always balances is a report
  nobody can learn anything from.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
  def viewer_events, do: ~w(filter select_donation)

  alias EstoqueOS.Missions

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    panel = Missions.panel(Missions.get_mission!(id))

    {:ok,
     socket
     |> assign(:page_title, panel.mission.name)
     |> assign(:only_open, false)
     |> assign(:error, nil)
     |> assign(:candidates, Missions.donation_candidates(panel.mission))
     |> assign(:selected, MapSet.new())
     |> assign(:panel, panel)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, assign(socket, :only_open, params["only_open"] == "true")}
  end

  # Ticking a line moves nothing. The whole panel is a suggestion until the
  # operator carries it over to the write-off screen, which is where a movement
  # is actually posted and where the permissions for posting one live.
  def handle_event("select_donation", params, socket) do
    selected =
      params
      |> Map.get("lots", [])
      |> Enum.flat_map(fn value ->
        case Integer.parse(value) do
          {id, ""} -> [id]
          _ -> []
        end
      end)
      |> MapSet.new()

    {:noreply, assign(socket, :selected, selected)}
  end

  # A navigation, not a write: the write-off screen is the one that asks for a
  # recipient and posts the transaction. Ticking here and pressing there is the
  # same two-step every donation already goes through — this only skips typing
  # six product names into a search box while standing in a hospital corridor.
  def handle_event("donate", _params, socket) do
    if Enum.empty?(socket.assigns.selected) do
      {:noreply, socket}
    else
      {:noreply,
       push_navigate(socket, to: donate_path(socket.assigns.panel, socket.assigns.selected))}
    end
  end

  def handle_event("reschedule", params, socket) do
    attrs = Map.take(params, ~w(starts_on ends_on tables))

    case Missions.update_mission(socket.assigns.panel.mission, attrs) do
      {:ok, mission} ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:panel, Missions.panel(Missions.get_mission!(mission.id)))
         |> put_flash(:info, gettext("Dates updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, first_error(changeset))}
    end
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> List.first()
    |> Kernel.||(gettext("Those dates could not be saved."))
  end

  defp visible_lines(%{lines: lines}, true) do
    Enum.reject(lines, &Decimal.equal?(&1.unaccounted, Decimal.new(0)))
  end

  defp visible_lines(%{lines: lines}, _all), do: lines

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/missions"} back_label={gettext("Missions")}>
        {@panel.mission.name}
        <:subtitle>
          {gettext("%{where} · left %{left}",
            where: @panel.mission.location.name,
            left: date(@panel.mission.starts_on)
          )}
          {gettext("· returns %{back}", back: date(@panel.mission.ends_on))}
        </:subtitle>
      </.header>

      <!-- Plans change: the flight home moves, the team stays an extra day. The
           dates are what somebody wrote down, not something the ledger decided,
           so they are editable without touching a single movement. -->
      <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
        <form
          id="mission-dates"
          phx-submit="reschedule"
          class="field-row mt-4"
        >
          <label class="fieldset">
            <span class="label">{gettext("Leaves on")}</span>
            <input
              type="date"
              name="starts_on"
              value={@panel.mission.starts_on}
              class="input input-bordered"
              required
            />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Returns on")}</span>
            <input
              type="date"
              name="ends_on"
              value={@panel.mission.ends_on}
              class="input input-bordered"
              required
            />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Tables")}</span>
            <input
              type="number"
              name="tables"
              min="1"
              value={@panel.mission.tables}
              class="input input-bordered w-20"
            />
          </label>
          <.button>{gettext("Save dates")}</.button>
        </form>
      </.write_gate>

      <p :if={@error} class="alert alert-error mt-3">{@error}</p>

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mt-6">
        <.stat label={gettext("Sent")} value={quantity(@panel.totals.sent)} />
        <.stat label={gettext("Returned")} value={quantity(@panel.totals.returned)} />
        <.stat
          label={gettext("Used")}
          value={quantity(@panel.totals.consumed)}
          hint={per_table_hint(assigns)}
        />
        <.stat
          label={gettext("Donated")}
          value={quantity(@panel.totals.donated)}
          hint={gettext("handed over, not used up")}
        />
      </div>

      <!-- Only shown when it happened. Stock does not always come home between
           trips, and a column of zeroes teaches nobody anything. -->
      <div :if={not Decimal.equal?(@panel.totals.handed_on, Decimal.new(0))} class="mt-3">
        <.stat
          label={gettext("Went on to the next mission")}
          value={quantity(@panel.totals.handed_on)}
          hint={gettext("left without coming home first — not lost, moved on")}
        />
      </div>

      <div
        :if={not Decimal.equal?(@panel.totals.unaccounted, Decimal.new(0))}
        class="alert alert-warning mt-4"
      >
        {gettext(
          "%{units} unit(s) the ledger cannot place: sent, but neither returned, used, donated nor moved on.",
          units: quantity(@panel.totals.unaccounted)
        )}
        <span :if={not Decimal.equal?(@panel.still_there, Decimal.new(0))}>
          {gettext("%{units} are still on the books at %{where}.",
            units: quantity(@panel.still_there),
            where: @panel.mission.location.name
          )}
        </span>
      </div>

      <%!-- Shown only when the site still holds something with a short life left.
            An empty panel on every closed mission would be a heading that means
            "nothing to do" in a screen already full of numbers. --%>
      <.panel :if={@candidates != []} title={gettext("Donate before it expires")} flush>
        <p class="px-4 pt-3 text-sm text-base-content/70">
          {gettext(
            "Still at %{where}, soonest expiry first. Handing these over now costs a signature; flying them home costs the goods.",
            where: @panel.mission.location.name
          )}
        </p>

        <form id="donation-picks" phx-change="select_donation">
          <.data_table rows={@candidates} row_id={&"candidate-#{&1.lot_id}"}>
            <:col :let={row} label={gettext("Take")}>
              <.check
                name="lots[]"
                value={to_string(row.lot_id)}
                label={gettext("Donate")}
                checked={MapSet.member?(@selected, row.lot_id)}
              />
            </:col>
            <:col :let={row} label={gettext("Product")} emphasis={:identity}>
              <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
                {row.product}
              </.link>
              <.status :if={row.controlled} kind={:controlled} />
            </:col>
            <:col :let={row} label={gettext("Lot")}>{row.lot_number}</:col>
            <:col :let={row} label={gettext("Box")}>{row.box}</:col>
            <:col :let={row} label={gettext("Expires")}>
              {date(row.expires_on)}
              <span class="block text-xs text-base-content/60">{expiry_hint(row)}</span>
            </:col>
            <:col :let={row} label={gettext("Quantity")} align={:right} emphasis={:primary}>
              {quantity(row.quantity)}
            </:col>
          </.data_table>
        </form>

        <div class="p-4">
          <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
            <.button phx-click="donate" disabled={Enum.empty?(@selected)}>
              {gettext("Donate selected")}
            </.button>
          </.write_gate>
        </div>
      </.panel>

      <form id="lines-filter" phx-change="filter" class="flex items-center gap-2 mt-6">
        <.check
          name="only_open"
          label={gettext("Only lines that do not add up")}
          checked={@only_open}
        />
      </form>

      <.panel title={gettext("Mission lines")} flush>
        <.data_table
          rows={visible_lines(@panel, @only_open)}
          row_id={&"line-#{&1.product_id}"}
        >
          <:empty>
            <.empty
              title={gettext("Nothing has moved for this mission yet.")}
              note={gettext("It starts when the first load-out sends a box to this mission.")}
            >
              <:actions>
                <.button navigate={~p"/load-out"}>
                  {gettext("Load-out")}
                </.button>
              </:actions>
            </.empty>
          </:empty>

          <:col :let={line} label={gettext("Product")} emphasis={:identity}>
            <.link navigate={~p"/products/#{line.product_id}"} class="link link-hover">
              {line.product}
            </.link>
            <.status :if={line.controlled} kind={:controlled} />
          </:col>
          <:col :let={line} label={gettext("Sent")} align={:right} emphasis={:primary}>
            {quantity(line.sent)}
          </:col>
          <:col :let={line} label={gettext("Returned")} align={:right}>
            {quantity(line.returned)}
          </:col>
          <:col :let={line} label={gettext("Used")} align={:right}>{quantity(line.consumed)}</:col>
          <:col :let={line} label={gettext("Donated")} align={:right}>
            {quantity(line.donated)}
          </:col>
          <:col :let={line} label={gettext("Moved on")} align={:right}>
            {quantity(line.handed_on)}
          </:col>
          <:col :let={line} label={gettext("Unplaced")} align={:right}>
            <span class={unplaced_class(line.unaccounted)}>{quantity(line.unaccounted)}</span>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  # Comparing two missions only means something per table: a trip with six
  # tables is expected to use more than one with four.
  defp per_table_hint(assigns) do
    case Missions.consumption_per_table(assigns.panel) do
      nil -> gettext("record the number of tables to compare missions")
      per_table -> gettext("%{value} per table", value: quantity(per_table))
    end
  end

  # Days, not a date, because "expires 12/09" needs a calendar and "in 11 days"
  # does not — and the question this panel asks is whether the trip home is
  # longer than what the item has left.
  defp expiry_hint(%{days_left: days}) when days < 0 do
    gettext("expired %{days} day(s) ago", days: abs(days))
  end

  defp expiry_hint(%{days_left: days}), do: gettext("in %{days} day(s)", days: days)

  # Lot ids in the address, not a basket carried across the socket: the write-off
  # screen rebuilds the lines from the ledger, so a link that sat in a tab
  # overnight cannot post yesterday's quantities.
  defp donate_path(%{mission: mission}, selected) do
    lots = selected |> Enum.sort() |> Enum.join(",")

    ~p"/issue?donate=#{lots}&location=#{mission.location_id}"
  end

  defp unplaced_class(value) do
    if Decimal.equal?(value, Decimal.new(0)), do: "opacity-50", else: "text-warning font-medium"
  end
end
