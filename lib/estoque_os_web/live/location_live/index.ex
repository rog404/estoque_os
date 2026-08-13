defmodule EstoqueOSWeb.LocationLive.Index do
  @moduledoc """
  The places stock can be: warehouses, mission sites, and the transit location
  that mirrors "estoque em trânsito" in the accounting.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Inventory.Location
  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Locations"))
     |> load_locations()}
  end

  defp load_locations(socket) do
    socket
    |> assign(:locations, Locations.list_locations())
    |> assign(:overview, Locations.location_overview())
    |> assign(:editing, nil)
  end

  defp overview(assigns, location) do
    Map.get(assigns.overview, location.id, %{boxes: 0, known_value: Decimal.new(0)})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Locations")}
        <:subtitle>
          {gettext("Warehouses, mission sites, and stock that is on its way.")}
        </:subtitle>
      </.header>

      <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
        <form
          id="new-location"
          phx-submit="create"
          class="field-row mt-4"
        >
          <label class="fieldset">
            <span class="label">{gettext("New location")}</span>
            <input
              type="text"
              name="name"
              placeholder={gettext("e.g. Missão Tefé")}
              class="input input-bordered w-64"
              aria-label={gettext("Location name")}
            />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Kind")}</span>
            <select name="kind" class="select select-bordered">
              <option :for={kind <- Location.kinds()} value={kind}>{kind_label(kind)}</option>
            </select>
          </label>
          <.button phx-disable-with={gettext("Creating...")}>{gettext("Create location")}</.button>
        </form>
      </.write_gate>

      <.panel title={gettext("Locations")} flush>
        <.data_table rows={@locations} row_id={&"location-#{&1.id}"}>
          <:empty>
            <.empty
              title={gettext("No location registered yet.")}
              note={gettext("The warehouse, and each mission the stock travels to.")}
            />
          </:empty>

          <:col :let={location} label={gettext("Location")} emphasis={:identity}>
            <form
              :if={@editing == location.id}
              id={"rename-#{location.id}"}
              phx-submit="rename"
              phx-value-id={location.id}
              class="flex items-center gap-2"
            >
              <input
                type="text"
                name="name"
                value={location.name}
                class="input input-sm input-bordered"
                aria-label={gettext("New name for %{name}", name: location.name)}
                phx-mounted={JS.focus()}
              />
              <button class="btn btn-sm btn-primary">{gettext("Save")}</button>
              <button type="button" phx-click="cancel_rename" class="btn btn-sm btn-ghost">
                {gettext("Cancel")}
              </button>
            </form>
            <span :if={@editing != location.id}>{location.name}</span>
          </:col>

          <:col :let={location} label={gettext("Kind")}>{kind_label(location.kind)}</:col>

          <:col :let={location} label={gettext("Boxes")} align={:right} emphasis={:primary}>
            {overview(assigns, location).boxes}
          </:col>

          <:col :let={location} :if={@sees_money?} label={gettext("Known value")} align={:right}>
            <.amount value={money(overview(assigns, location).known_value)} />
          </:col>

          <:col :let={location} label={gettext("Actions")} hide_label_on_card={true}>
            <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
              <div class="flex items-center gap-1">
                <button
                  type="button"
                  phx-click="edit"
                  phx-value-id={location.id}
                  class="btn btn-ghost btn-square btn-sm"
                  aria-label={gettext("Rename %{name}", name: location.name)}
                  title={gettext("Rename")}
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </button>

                <!-- Disabled, never absent — and the reason is the sentence that
                   says what to do about it. A location with boxes in it used to
                   swap the button for the words "holds boxes", which reads as a
                   fact about the row rather than as the thing standing between
                   you and deactivating it. -->
                <.commit_action
                  id={"deactivate-#{location.id}"}
                  form={"deactivate-form-#{location.id}"}
                  label={gettext("Deactivate")}
                  title={gettext("Deactivate %{name}?", name: location.name)}
                  confirm_label={gettext("Deactivate")}
                  tone={:danger}
                  disabled={overview(assigns, location).boxes > 0}
                  reason={gettext("Move or deactivate its boxes first.")}
                >
                  <:consequence>
                    {gettext(
                      "It disappears from every picker. Movements already recorded keep naming it, so the history stays readable."
                    )}
                  </:consequence>
                </.commit_action>
              </div>
            </.write_gate>

            <form
              :if={overview(assigns, location).boxes == 0}
              id={"deactivate-form-#{location.id}"}
              phx-submit="deactivate"
              phx-value-id={location.id}
              class="hidden"
            />
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp kind_label("warehouse"), do: gettext("warehouse")
  defp kind_label("mission_site"), do: gettext("mission site")
  defp kind_label("transit"), do: gettext("in transit")
  defp kind_label("other"), do: gettext("other")

  @impl true
  def handle_event("create", %{"name" => name, "kind" => kind}, socket) do
    case Locations.create_location(%{name: name, kind: kind}) do
      {:ok, location} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Location %{name} created.", name: location.name))
         |> load_locations()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Give the location a name that is not in use yet."))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing, String.to_integer(id))}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("rename", %{"id" => id, "name" => name}, socket) do
    location = Locations.get_location!(id)

    case Locations.update_location(location, %{name: name}) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Now called %{name}.", name: renamed.name))
         |> load_locations()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Give the location a name that is not in use yet."))}
    end
  end

  # Guarded here too, not only in the markup: hiding the trigger is presentation,
  # and the boxes could have arrived between render and click.
  def handle_event("deactivate", %{"id" => id}, socket) do
    location = Locations.get_location!(id)

    case Locations.list_boxes(location.id) do
      [] ->
        {:ok, _} = Locations.deactivate_location(location)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} was deactivated.", name: location.name))
         |> load_locations()}

      boxes ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{name} still holds %{count} box(es). Move them first.",
             name: location.name,
             count: length(boxes)
           )
         )}
    end
  end
end
