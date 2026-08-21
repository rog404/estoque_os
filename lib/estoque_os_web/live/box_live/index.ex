defmodule EstoqueOSWeb.BoxLive.Index do
  @moduledoc """
  Where every box is and what it is presumed to hold.

  Moving a box is one select and one click on purpose: between missions this
  happens dozens of times, and demanding a recount for each move is exactly
  what makes people stop using the system.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Inventory.Locations

  @stale_after_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Boxes"))
     |> assign(:locations, Locations.list_locations())
     |> assign(:by_hand, Enum.filter(Locations.list_locations(), &by_hand?/1))
     |> assign(:form, to_form(Locations.change_box(%EstoqueOS.Inventory.Box{})))
     |> load_boxes()}
  end

  defp load_boxes(socket), do: assign(socket, :rows, Locations.list_boxes_with_contents())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Boxes")}
        <:subtitle>
          {gettext(
            "Moving a box moves what it holds. No recount is required. Sending one to a mission is a load-out."
          )}
        </:subtitle>
      </.header>

      <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
        <form
          id="new-box"
          phx-submit="create"
          class="field-row mt-4"
        >
          <label class="fieldset">
            <span class="label">{gettext("New box")}</span>
            <input
              type="text"
              name="code"
              placeholder="AN01"
              class="input input-bordered w-32"
              aria-label={gettext("Box code")}
            />
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Location")}</span>
            <select name="location_id" class="select select-bordered">
              <option :for={location <- @locations} value={location.id}>{location.name}</option>
            </select>
          </label>
          <.button phx-disable-with={gettext("Creating...")}>{gettext("Create box")}</.button>
        </form>
      </.write_gate>

      <!-- No title: the page header two lines up already says "Caixas", and
           stacking the same word over its own column labels was most of what
           made this area read as clutter. -->
      <.panel flush>
        <.data_table rows={@rows} row_id={&"box-#{&1.box.id}"}>
          <:empty>
            <.empty
              title={gettext("No box registered yet.")}
              note={
                gettext(
                  "A box is what travels. Register the ones the logistics operator already uses, with the codes written on them."
                )
              }
            />
          </:empty>

          <:col :let={row} label={gettext("Box")} emphasis={:identity}>
            <.link navigate={~p"/boxes/#{row.box}"} class="link-hover">
              <.box_code code={row.box.code} />
            </.link>
          </:col>

          <:col :let={row} label={gettext("Location")}>
            {row.box.location.name}
            <.status :if={row.box.location.kind == "transit"} kind={:in_transit} />
          </:col>

          <:col :let={row} label={gettext("Presumed contents")} align={:right} emphasis={:primary}>
            {quantity(row.quantity)}
            <p class="text-sm font-normal text-base-content/80">
              {gettext("in %{count} position(s)", count: row.positions)}
            </p>
          </:col>

          <:col :let={row} label={gettext("Last count")}>
            <span class={stale_class(row.box)}>{verified_label(row.box)}</span>
          </:col>

          <:col :let={row} label={gettext("Move to")}>
            <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
              <form
                id={"move-#{row.box.id}"}
                phx-submit="move"
                phx-value-box={row.box.id}
                class="flex items-center gap-2"
              >
                <!-- Only the places a box may be carried to by hand. A mission
                     site and transit are missing on purpose: arriving at one is
                     the moment a movement acquires a reason — which trip it
                     belongs to — and only the load-out asks. -->
                <select
                  name="location_id"
                  class="select select-bordered"
                  aria-label={gettext("Move box %{code} to", code: row.box.code)}
                >
                  <option
                    :for={location <- @by_hand}
                    value={location.id}
                    disabled={location.id == row.box.location_id}
                  >
                    {location.name}
                  </option>
                </select>
                <button class="btn" phx-disable-with={gettext("Moving...")}>{gettext("Move")}</button>
              </form>
            </.write_gate>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp by_hand?(%{kind: kind}), do: kind not in ~w(mission_site transit)

  defp stale_class(box) do
    if stale?(box), do: "text-warning", else: "opacity-70"
  end

  defp stale?(%{last_verified_at: nil}), do: true

  defp stale?(%{last_verified_at: verified_at}) do
    DateTime.diff(DateTime.utc_now(), verified_at, :day) > @stale_after_days
  end

  defp verified_label(%{last_verified_at: nil}), do: gettext("never counted")

  defp verified_label(%{last_verified_at: verified_at}) do
    date(verified_at)
  end

  @impl true
  def handle_event("create", %{"code" => code, "location_id" => location_id}, socket) do
    case Locations.create_box(%{code: code, location_id: location_id}) do
      {:ok, box} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Box %{code} created.", code: box.code))
         |> load_boxes()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Give the box a code that is not in use yet."))}
    end
  end

  def handle_event("move", %{"box" => box_id, "location_id" => location_id}, socket) do
    box = Locations.get_box!(box_id)
    user_id = socket.assigns.current_scope.user.id

    case Locations.move_box(box, location_id, user_id: user_id) do
      {:ok, %{box: moved}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Box %{code} moved to %{location}.",
             code: moved.code,
             location: moved.location.name
           )
         )
         |> load_boxes()}

      {:error, :same_location} ->
        {:noreply, put_flash(socket, :error, gettext("The box is already there."))}

      {:error, :load_out_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A box goes to a mission through the load-out, which records the trip.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The box could not be moved."))}
    end
  end
end
