defmodule EstoqueOSWeb.KitLive.Index do
  @moduledoc """
  Kits and what the stock can actually cover.

  The number that matters before a mission is not "how many kits exist" but
  "how many can I put together, and what stops the next one".
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Picking a location only changes what availability is reported for.
  """
  def viewer_events, do: ~w(location)

  alias EstoqueOS.Kits

  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(_params, _session, socket) do
    locations = Locations.list_locations()
    location = Locations.default_location() || List.first(locations)

    {:ok,
     socket
     |> assign(:page_title, gettext("Kits"))
     |> assign(:locations, locations)
     |> assign(:location_id, location && location.id)
     |> assign(:error, nil)
     |> load_kits()}
  end

  defp load_kits(socket) do
    location_id = socket.assigns.location_id

    kits =
      Enum.map(Kits.list_kits(), fn kit ->
        %{kit: kit, availability: location_id && Kits.availability(kit, location_id)}
      end)

    assign(socket, :kits, kits)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Kits")}
        <:subtitle>{gettext("What the stock at a location can cover.")}</:subtitle>
      </.header>

      <form id="location-form" phx-change="location" class="mt-4">
        <label class="fieldset">
          <span class="label">{gettext("Location")}</span>
          <select name="location_id" class="select select-bordered">
            <option
              :for={location <- @locations}
              value={location.id}
              selected={location.id == @location_id}
            >
              {location.name}
            </option>
          </select>
        </label>
      </form>

      <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
        <form
          id="new-kit"
          phx-submit="create"
          class="field-row mt-4"
        >
          <label class="fieldset grow min-w-64">
            <span class="label">{gettext("New kit")}</span>
            <input
              type="text"
              name="name"
              placeholder={gettext("Kit Recuperação")}
              class="input input-bordered w-full"
              required
            />
          </label>
          <.button variant="primary">{gettext("Create kit")}</.button>
        </form>
      </.write_gate>

      <p :if={@error} class="alert alert-error mt-3">{@error}</p>

      <p :if={@kits == []} class="mt-8 opacity-70">{gettext("No kit registered yet.")}</p>

      <div class="grid lg:grid-cols-2 gap-4 mt-6">
        <section :for={row <- @kits} class="panel">
          <div class="panel-body">
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="font-semibold">
                <.link navigate={~p"/kits/#{row.kit}"} class="link link-hover">
                  {row.kit.name}
                </.link>
              </h2>
              <p class="text-sm opacity-70">
                {gettext("%{count} component(s)", count: length(row.kit.items))}
              </p>
            </div>

            <p :if={row.availability} class="text-2xl font-semibold">
              {quantity(row.availability.possible)}
              <span class="text-sm font-normal opacity-70">{gettext("kits possible")}</span>
            </p>

            <p
              :if={
                row.availability && row.availability.bottlenecks != [] &&
                  Decimal.compare(row.availability.possible, 100) == :lt
              }
              class="text-sm opacity-70"
            >
              {gettext("held back by: %{items}", items: bottleneck_names(row.availability))}
            </p>

            <p
              :if={row.availability && row.availability.unresolved != []}
              class="text-sm text-warning"
            >
              {gettext("%{count} component(s) not linked to a product yet",
                count: length(row.availability.unresolved)
              )}
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp bottleneck_names(availability) do
    availability.bottlenecks
    |> Enum.map(& &1.item.description)
    |> Enum.take(3)
    |> Enum.join(", ")
  end

  @impl true
  def handle_event("create", %{"name" => name}, socket) do
    # A kit starts empty and gains its components on its own screen. Asking for
    # the whole bill of materials in one form is how a kit gets half entered.
    case Kits.create_kit(%{name: String.trim(name)}) do
      {:ok, kit} ->
        {:noreply, push_navigate(socket, to: ~p"/kits/#{kit.id}")}

      {:error, _changeset} ->
        {:noreply, assign(socket, :error, gettext("There is already a kit with that name."))}
    end
  end

  def handle_event("location", %{"location_id" => location_id}, socket) do
    {:noreply,
     socket
     |> assign(:location_id, String.to_integer(location_id))
     |> load_kits()}
  end
end
