defmodule EstoqueOSWeb.LocationLive.Index do
  @moduledoc """
  The places stock can be: warehouses, mission sites, and the transit location
  that mirrors "estoque em trânsito" in the accounting.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.Location
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOSWeb.StockLive

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Locations"))
     |> assign(:search, "")
     |> load_locations()}
  end

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Searching narrows a list and writes nothing.
  """
  def viewer_events, do: ~w(search)

  # One list, retired places included and marked. Two tables said the same thing
  # twice and put the same location's history in two places on the page — a
  # retired mission site is still a mission site, and the row that says so is
  # the row that brings it back.
  defp load_locations(socket) do
    socket
    |> assign(
      :locations,
      Enum.filter(Locations.list_all_locations(), &matches?(&1, socket.assigns.search))
    )
    |> assign(:overview, Locations.location_overview())
    |> assign(:editing, nil)
  end

  # By name or by kind, because "depósito" and "missão" are how somebody asks
  # for a group of them, and a warehouse with thirty mission sites is a list
  # nobody scrolls.
  defp matches?(_location, ""), do: true

  defp matches?(location, search) do
    term = normalize(search)

    String.contains?(normalize(location.name), term) or
      String.contains?(normalize(kind_label(location.kind)), term)
  end

  defp normalize(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  defp overview(assigns, location) do
    Map.get(assigns.overview, location.id, %{
      boxes: 0,
      loose: Decimal.new(0),
      known_value: Decimal.new(0)
    })
  end

  # Retiring a place hides it from every picker, so it may only happen once
  # nothing is standing there — in a box or loose on the floor.
  defp retirable?(assigns, location) do
    counts = overview(assigns, location)

    counts.boxes == 0 and Decimal.compare(counts.loose, 0) != :gt
  end

  # And the reason says which of the two it is, because the fix is different:
  # boxes are moved, loose stock is written off or entered into a box.
  defp retirement_block(assigns, location) do
    counts = overview(assigns, location)

    cond do
      counts.boxes > 0 -> gettext("Move or deactivate its boxes first.")
      Decimal.compare(counts.loose, 0) == :gt -> gettext("It still holds loose stock.")
      true -> nil
    end
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

      <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
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

      <form id="location-search" phx-change="search" class="mt-4">
        <label class="input flex items-center gap-2 w-full max-w-md">
          <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
          <span class="sr-only">{gettext("Search")}</span>
          <input
            type="search"
            name="search"
            value={@search}
            placeholder={gettext("Location name or kind")}
            class="grow"
            phx-debounce="300"
          />
        </label>
      </form>

      <.panel title={gettext("Locations")} flush>
        <.data_table rows={@locations} row_id={&"location-#{&1.id}"}>
          <:empty>
            <!-- Two different facts: a search that matched nothing is not an
                 operation without places to keep stock. -->
            <.empty
              :if={@search != ""}
              title={gettext("No location matches that.")}
              note={gettext("Search by the name, or by the kind of place it is.")}
            />
            <.empty
              :if={@search == ""}
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
              <.button variant="primary" class="btn-sm">{gettext("Save")}</.button>
              <.button variant="ghost" type="button" phx-click="cancel_rename" class="btn-sm">
                {gettext("Cancel")}
              </.button>
            </form>
            <span :if={@editing != location.id}>{location.name}</span>
            <!-- Said on the row rather than by living in a second table: a
                 retired place is the same place, and what somebody looks for
                 when they come here is the name. -->
            <span :if={not location.active} class="badge is-quiet ml-2">
              {gettext("deactivated")}
            </span>
          </:col>

          <:col :let={location} label={gettext("Kind")}>{kind_label(location.kind)}</:col>

          <!-- Which stock arrives here by default. Surgical supplies come into
               the warehouse and marketing material into the office, and every
               screen that preselects a place reads this — so setting it once
               here is what stops one of the two coordinators correcting the
               location on every single entry. -->
          <:col :let={location} label={gettext("Entry point for")}>
            <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
              <form id={"default-#{location.id}"} phx-change="set_default">
                <input type="hidden" name="location_id" value={location.id} />
                <select
                  name="segment"
                  class="select select-sm select-bordered"
                  disabled={not location.active}
                  aria-label={gettext("Entry point for %{name}", name: location.name)}
                >
                  <option value="" selected={is_nil(location.default_for_segment)}>
                    {gettext("no stock")}
                  </option>
                  <option
                    :for={segment <- Product.segments()}
                    value={segment}
                    selected={location.default_for_segment == segment}
                  >
                    {StockLive.Index.segment_label(segment)}
                  </option>
                </select>
              </form>
            </.write_gate>
          </:col>

          <:col :let={location} label={gettext("Boxes")} align={:right} emphasis={:primary}>
            {overview(assigns, location).boxes}
          </:col>

          <:col :let={location} :if={@sees_money?} label={gettext("Known value")} align={:right}>
            <.amount value={money(overview(assigns, location).known_value)} />
          </:col>

          <:col :let={location} label={gettext("Actions")} hide_label_on_card={true}>
            <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
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
                <!-- One slot, one control: a working place can be retired, a
                     retired one can come back, and no row ever shows both. The
                     slot has a width so the two buttons occupy the same space
                     and the column does not shift as the list is filtered. -->
                <div class="w-28 shrink-0">
                  <.commit_action
                    :if={location.active}
                    id={"deactivate-#{location.id}"}
                    form={"deactivate-form-#{location.id}"}
                    label={gettext("Deactivate")}
                    title={gettext("Deactivate %{name}?", name: location.name)}
                    confirm_label={gettext("Deactivate")}
                    tone={:danger}
                    disabled={not retirable?(assigns, location)}
                    reason={retirement_block(assigns, location)}
                  >
                    <:consequence>
                      {gettext(
                        "It disappears from every picker. Movements already recorded keep naming it, so the history stays readable."
                      )}
                    </:consequence>
                  </.commit_action>

                  <!-- A mission that ran last year runs again, and the name is
                       unique — so the way back is this row rather than a second
                       location typed in with the same name, which the database
                       refuses and which would split the history in two if it
                       did not. -->
                  <.button
                    :if={not location.active}
                    type="button"
                    phx-click="reactivate"
                    phx-value-id={location.id}
                    class="btn-sm w-full"
                  >
                    {gettext("Reactivate")}
                  </.button>
                </div>
              </div>
            </.write_gate>

            <form
              :if={location.active and retirable?(assigns, location)}
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp default_message(%{default_for_segment: nil} = location) do
    gettext("%{name} is no longer an entry point.", name: location.name)
  end

  defp default_message(location) do
    gettext("%{stock} now arrives at %{name}.",
      stock: StockLive.Index.segment_label(location.default_for_segment),
      name: location.name
    )
  end

  defp kind_label("warehouse"), do: gettext("warehouse")
  defp kind_label("mission_site"), do: gettext("mission site")
  defp kind_label("transit"), do: gettext("in transit")
  defp kind_label("other"), do: gettext("other")

  @impl true
  def handle_event("search", params, socket) do
    {:noreply, socket |> assign(:search, params["search"] || "") |> load_locations()}
  end

  # One place per stock, so this both sets the new one and clears whoever held
  # it — decided in the context, where the uniqueness lives.
  def handle_event("set_default", %{"location_id" => id, "segment" => segment}, socket) do
    location = Locations.get_location!(id)

    case Locations.set_default_for_segment(location, blank_to_nil(segment)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, default_message(updated))
         |> load_locations()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That entry point could not be set."))}
    end
  end

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
  # and the boxes could have arrived between render and click. The context
  # answers, so the screen and a hand-made event get the same answer — and the
  # answer now covers stock lying loose at the place, not only its boxes.
  def handle_event("deactivate", %{"id" => id}, socket) do
    location = Locations.get_location!(id)

    case Locations.deactivate_location(location) do
      {:ok, _location} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} was deactivated.", name: location.name))
         |> load_locations()}

      {:error, :not_empty} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("%{name} still holds stock. Empty it first.", name: location.name)
         )
         |> load_locations()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That location could not be deactivated."))}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    location = Locations.get_location!(id)
    {:ok, _} = Locations.reactivate_location(location)

    {:noreply,
     socket
     |> put_flash(:info, gettext("%{name} is back in use.", name: location.name))
     |> load_locations()}
  end
end
