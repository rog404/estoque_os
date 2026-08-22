defmodule EstoqueOSWeb.BoxLive.Index do
  @moduledoc """
  Where every box is and what it is presumed to hold.

  Moving a box is one select and one click on purpose: between missions this
  happens dozens of times, and demanding a recount for each move is exactly
  what makes people stop using the system.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Auditing
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
     |> assign(:search, "")
     |> load_boxes()}
  end

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Searching narrows a list and writes nothing.
  """
  def viewer_events, do: ~w(search)

  # In the order somebody should work through them, not alphabetically. The
  # guided list this replaces was a second page ranking the same boxes; a list
  # that is already the queue cannot disagree with itself. `Auditing.priorities/0`
  # carries the reasons too, so the row can say why it is near the top.
  defp load_boxes(socket) do
    priorities = Auditing.priorities()

    rows =
      Locations.list_boxes_with_contents()
      |> Enum.map(&Map.put(&1, :priority, priorities[&1.box.id]))
      |> Enum.filter(&matches?(&1, socket.assigns.search))
      |> Enum.sort_by(&queue_order/1)

    assign(socket, :rows, rows)
  end

  # The code written on the box in marker pen, or where it is standing. Both,
  # because the two questions asked in front of a shelf are "where is AN01" and
  # "what is at the São Paulo office", and typing is faster than reading a
  # hundred rows either way.
  defp matches?(_row, ""), do: true

  defp matches?(%{box: box}, search) do
    term = normalize(search)

    String.contains?(normalize(box.code), term) or
      String.contains?(normalize(box.location.name), term)
  end

  defp normalize(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  # Highest score first; among boxes the score cannot separate — an empty box
  # has no score at all — the one nobody has counted, then the one counted
  # longest ago, then the code, so the order is stable between two page loads.
  defp queue_order(%{priority: priority, box: box}) do
    {-(priority[:score] || 0), verified_order(box.last_verified_at), box.code}
  end

  defp verified_order(nil), do: {0, 0}
  defp verified_order(verified_at), do: {1, DateTime.to_unix(verified_at)}

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

      <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
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

      <form id="box-search" phx-change="search" class="mt-4">
        <label class="input flex items-center gap-2 w-full max-w-md">
          <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
          <span class="sr-only">{gettext("Search")}</span>
          <input
            type="search"
            name="search"
            value={@search}
            placeholder={gettext("Box code or location")}
            class="grow"
            phx-debounce="300"
          />
        </label>
      </form>

      <!-- No title: the page header two lines up already says "Caixas", and
           stacking the same word over its own column labels was most of what
           made this area read as clutter. -->
      <.panel flush>
        <.data_table rows={@rows} row_id={&"box-#{&1.box.id}"}>
          <:empty>
            <!-- Two different facts, and the same empty table said only the
                 first: a warehouse with a hundred boxes and a search that
                 matched none of them is not a warehouse without boxes. -->
            <.empty
              :if={@search != ""}
              title={gettext("No box matches that.")}
              note={gettext("Search by the code written on the box, or by where it is standing.")}
            />
            <.empty
              :if={@search == ""}
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
              {gettext("in %{count} lot(s)", count: row.positions)}
            </p>
          </:col>

          <:col :let={row} label={gettext("Last count")}>
            <span class={stale_class(row.box)}>{verified_label(row.box)}</span>

            <!-- Why this box is where it is in the list. Without it the order is
                 a ranking nobody understands, which is a ranking nobody
                 follows — and the page that used to explain it is gone. -->
            <div :if={reasons(row) != []} class="flex flex-wrap gap-1 mt-1">
              <span
                :for={{kind, label} <- reasons(row)}
                class={["badge badge-sm", reason_class(kind)]}
              >
                {label}
              </span>
            </div>
          </:col>

          <:col :let={row} label={gettext("Counting")}>
            <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
              <.link navigate={~p"/boxes/#{row.box}/count"} class="btn btn-sm">
                {gettext("Count")}
              </.link>
            </.write_gate>
          </:col>

          <:col :let={row} label={gettext("Move to")}>
            <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
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

  # Never counted is already said by the cell above it, so it is dropped here
  # rather than printed twice on the same row.
  defp reasons(%{priority: nil}), do: []

  defp reasons(%{priority: priority}) do
    Enum.reject(priority.reasons, fn {kind, _label} -> kind == :never_counted end)
  end

  defp reason_class(:controlled), do: "badge-error"
  defp reason_class(:expiring), do: "badge-warning"
  defp reason_class(_kind), do: "badge-ghost"

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
  def handle_event("search", params, socket) do
    {:noreply, socket |> assign(:search, params["search"] || "") |> load_boxes()}
  end

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
