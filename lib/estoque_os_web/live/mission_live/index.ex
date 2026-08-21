defmodule EstoqueOSWeb.MissionLive.Index do
  @moduledoc """
  The trips, most recent first.

  A mission is created before it leaves, because the load-out has to have
  something to belong to. `ends_on` is left blank until it is over rather than
  guessed on the way out.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Creating a mission decides where the next load-out gets filed.
  """
  def viewer_events, do: ~w()

  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Missions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Missions"))
     |> assign(:sites, Missions.list_mission_sites())
     |> assign(:error, nil)
     |> load_missions()}
  end

  defp load_missions(socket), do: assign(socket, :missions, Missions.list_missions())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Missions")}
        <:subtitle>
          {gettext("Each surgical trip, and what it did to the stock.")}
        </:subtitle>
      </.header>

      <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
        <form
          id="new-mission"
          phx-submit="create"
          class="field-row mt-4"
        >
          <label class="fieldset">
            <span class="label">{gettext("Name")}</span>
            <input
              type="text"
              name="name"
              placeholder={gettext("Tefé 2026/1")}
              class="input input-bordered"
              required
            />
          </label>
          <!-- A mission usually goes somewhere the ONG has never been, so the
               place is created here rather than in a screen the coordinator has to
               visit first and come back from. -->
          <label class="fieldset">
            <span class="label">{gettext("Where")}</span>
            <select name="location_id" class="select select-bordered">
              <option value="">{gettext("— a new place —")}</option>
              <option :for={site <- @sites} value={site.id}>{site.name}</option>
            </select>
          </label>
          <label class="fieldset">
            <span class="label">{gettext("New place")}</span>
            <input
              type="text"
              name="new_location_name"
              placeholder={gettext("Missão Coari")}
              class="input input-bordered"
            />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Leaves on")}</span>
            <input type="date" name="starts_on" value={Date.utc_today()} class="input input-bordered" />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Returns on")}</span>
            <input type="date" name="ends_on" class="input input-bordered" required />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Tables")}</span>
            <input type="number" name="tables" min="1" class="input input-bordered w-20" />
          </label>
          <.button variant="primary">{gettext("Create mission")}</.button>
        </form>
      </.write_gate>

      <p :if={@error} class="alert alert-error mt-4">{@error}</p>

      <.panel title={gettext("Missions")} flush>
        <.data_table rows={@missions} row_id={&"mission-#{&1.id}"}>
          <:empty>
            <p class="opacity-80">{gettext("No mission recorded yet.")}</p>
          </:empty>

          <:col :let={mission} label={gettext("Mission")} emphasis={:identity}>
            <.link navigate={~p"/missions/#{mission.id}"} class="link link-hover">
              {mission.name}
            </.link>
          </:col>
          <:col :let={mission} label={gettext("Where")}>{mission.location.name}</:col>
          <:col :let={mission} label={gettext("Left")}>{date(mission.starts_on)}</:col>
          <:col :let={mission} label={gettext("Returned")}>
            {date(mission.ends_on)}
            <.status :if={under_way?(mission)} kind={:under_way} />
          </:col>
          <:col :let={mission} label={gettext("Tables")} align={:right}>
            {mission.tables || "—"}
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create", params, socket) do
    case resolve_location(params) do
      {:ok, location_id} ->
        params
        |> Map.take(~w(name starts_on ends_on tables notes))
        |> Map.put("location_id", location_id)
        |> blank_dates_to_nil()
        |> create(socket)

      {:error, message} ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  # Either an existing place or a new one, never both and never neither.
  defp resolve_location(params) do
    resolve_location(
      String.trim(params["location_id"] || ""),
      String.trim(params["new_location_name"] || "")
    )
  end

  defp resolve_location("", ""), do: {:error, gettext("Say where the mission goes.")}

  defp resolve_location("", named), do: create_site(named)

  defp resolve_location(picked, ""), do: {:ok, picked}

  defp resolve_location(_picked, _named) do
    {:error, gettext("Pick an existing place or name a new one, not both.")}
  end

  defp create_site(name) do
    case Locations.create_location(%{name: name, kind: "mission_site"}) do
      {:ok, location} -> {:ok, location.id}
      {:error, _changeset} -> {:error, gettext("There is already a place with that name.")}
    end
  end

  defp create(attrs, socket) do
    case Missions.create_mission(attrs) do
      {:ok, mission} ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:sites, Missions.list_mission_sites())
         |> put_flash(:info, gettext("Mission %{name} created.", name: mission.name))
         |> load_missions()}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, first_error(changeset))}
    end
  end

  # Presentation only: the planned return date is what the team booked, and
  # whether today falls inside it is worth a badge. Nothing about the stock is
  # decided from this.
  defp under_way?(mission) do
    today = Date.utc_today()

    Date.compare(mission.starts_on, today) != :gt and
      Date.compare(mission.ends_on, today) != :lt
  end

  # A different animal from `Coercion.blank_to_nil/1`, and it used to share the
  # name: this walks a *map* of form attrs. An empty date input posts "", which
  # is not the same as "no end date yet".
  defp blank_dates_to_nil(attrs) do
    Map.new(attrs, fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> List.first()
    |> Kernel.||(gettext("That mission could not be created."))
  end
end
