defmodule EstoqueOSWeb.BoxLive.Show do
  @moduledoc """
  What one box is presumed to hold, and where it has been.
  """

  use EstoqueOSWeb, :live_view

  import EstoqueOS.Coercion, only: [to_decimal: 1]

  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    box = Locations.get_box!(id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Box %{code}", code: box.code))
     |> assign(:locations, Locations.list_locations())
     |> assign(
       :by_hand,
       Enum.filter(Locations.list_locations(), &(&1.kind not in ~w(mission_site transit)))
     )
     |> assign(:new_box, nil)
     |> assign_box(box)}
  end

  defp assign_box(socket, box) do
    socket
    |> assign(:box, box)
    |> assign(:contents, Locations.box_contents(box))
    # The other boxes in the same room. Goods re-boxed anywhere else would be
    # goods moved between locations, which is a different act with a different
    # name.
    |> assign(:siblings, Enum.reject(Locations.list_boxes(box.location_id), &(&1.id == box.id)))
    # What is on the floor in the same room, waiting for a box.
    |> assign(:loose, Locations.loose_stock(box.location_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/boxes"} back_label={gettext("Boxes")}>
        {gettext("Box %{code}", code: @box.code)}
        <:subtitle>
          {@box.location.name} · {verified_label(@box)}
        </:subtitle>
        <:actions>
          <.write_gate may={@role_may_write?} allowed={@controls_enabled?}>
            <!-- Counting it and saying it was counted are different acts, and
                 this screen only offered the second. Somebody standing in front
                 of the box is already here; the blind count is a route away and
                 was reachable only from the mini-audit list. -->
            <.link navigate={~p"/boxes/#{@box}/count"} class="btn btn-primary btn-sm">
              {gettext("Count this box")}
            </.link>
            <button phx-click="verify" class="btn btn-outline btn-sm">
              {gettext("Mark as counted")}
            </button>

            <!-- Carrying the whole box somewhere else is an action on this box,
                 so it sits with the other two rather than floating between the
                 header and the contents. Loose there, it read as a caption on
                 the table below — a table whose own column moves *goods between
                 boxes*, which is a different act with a nearly identical name. -->
            <form id="move-form" phx-submit="move" class="flex items-center gap-2">
              <!-- Same rule as the Boxes listing: a mission and transit are not
                   places a box is carried to by hand. Arriving at one is where
                   the movement acquires a trip, and only the load-out asks
                   which. -->
              <select
                name="location_id"
                class="select select-sm select-bordered"
                aria-label={gettext("Where to carry this box")}
              >
                <option
                  :for={location <- @by_hand}
                  value={location.id}
                  disabled={location.id == @box.location_id}
                >
                  {location.name}
                </option>
              </select>
              <button class="btn btn-outline btn-sm" phx-disable-with={gettext("Moving...")}>
                {gettext("Carry the box there")}
              </button>
            </form>
          </.write_gate>
        </:actions>
      </.header>

      <.panel title={gettext("What is inside")} flush>
        <.data_table rows={@contents}>
          <:empty>
            <.empty
              title={gettext("This box is empty.")}
              note={gettext("Nothing is recorded inside it right now.")}
            />
          </:empty>

          <:col :let={row} label={gettext("Product")} emphasis={:identity}>{row.product}</:col>
          <:col :let={row} label={gettext("Lot")}>{row.lot_number || gettext("unknown")}</:col>
          <:col :let={row} label={gettext("Expiry")}>{date(row.expires_on)}</:col>
          <:col :let={row} label={gettext("Quantity")} align={:right} emphasis={:primary}>
            <span class="figure">{quantity(row.quantity)}</span>
          </:col>

          <!-- Re-boxing, per line. Two half-empty boxes become one, or a product
               goes where its group already lives. The quantity defaults to the
               whole line because that is the usual move, and part of it can be
               sent by typing less. -->
          <:col
            :let={row}
            :if={@role_may_write? and @siblings != []}
            label={gettext("Re-box into")}
            field={:block}
            group
          >
            <.write_gate may={true} allowed={@controls_enabled?}>
              <form
                id={"rebox-#{row.lot_id}"}
                phx-submit="rebox"
                phx-value-lot={row.lot_id}
                class="flex flex-wrap items-center gap-2 justify-end"
              >
                <input
                  type="text"
                  name="quantity"
                  value={quantity(row.quantity)}
                  inputmode="decimal"
                  data-numeric
                  class="input input-sm input-bordered w-20 text-right"
                  aria-label={gettext("How much to move")}
                />
                <.box_picker
                  name="box_code"
                  boxes={@siblings}
                  list_id="sibling-boxes"
                  label={gettext("Box to move into")}
                />
                <button class="btn btn-sm" phx-disable-with={gettext("Moving...")}>
                  {gettext("Move")}
                </button>

                <!-- Grows the row it's in, unlike the tick above — a deliberate
                     exception to "always render, never :if". The tick is a
                     passive confirmation glanced at while the thumb is already
                     moving to the next row, so a shift there lands the next tap
                     on the wrong line. This banner is a decision the operator
                     must answer before doing anything else; it appears exactly
                     where they are already looking and holds their next tap
                     inside itself, not on a sibling row. Reserving its height
                     in every row instead (its fix-sized sibling's remedy) was
                     tried and rejected: at "forty rows" (see the comment two
                     screens up) that is a table mostly made of blank space. -->
                <.new_box_confirm
                  :if={@new_box && @new_box.lot_id == to_string(row.lot_id)}
                  code={@new_box.code}
                  class="basis-full text-left"
                />
              </form>
            </.write_gate>
          </:col>
        </.data_table>
      </.panel>

      <!-- The answer to "how do I get a product with no box into one?", which
           until now was "you cannot". Loose stock is a real and temporary state
           — goods arrived and nobody has boxed them yet — and it is temporary
           because a load-out refuses to carry it: nothing identifies it at the
           other end and nothing brings it back. So this list is work, and it
           belongs on the screen of the box somebody is holding. -->
      <.panel
        :if={@role_may_write? and @loose != []}
        title={gettext("Loose here, with no box")}
        note={gettext("It cannot travel until it is in one.")}
        flush
      >
        <.data_table rows={@loose}>
          <:col :let={row} label={gettext("Product")} emphasis={:identity}>
            {row.product}
            <.status :if={row.controlled} kind={:controlled} />
          </:col>
          <:col :let={row} label={gettext("Lot")}>{row.lot_number || gettext("unknown")}</:col>
          <:col :let={row} label={gettext("Expiry")}>{date(row.expires_on)}</:col>
          <:col :let={row} label={gettext("Loose")} align={:right} emphasis={:primary}>
            <span class="figure">{quantity(row.quantity)}</span>
          </:col>

          <:col :let={row} label={gettext("Into this box")} field={:block} group>
            <.write_gate may={true} allowed={@controls_enabled?}>
              <form
                id={"stow-#{row.lot_id}"}
                phx-submit="stow"
                phx-value-lot={row.lot_id}
                class="flex flex-wrap items-center gap-2 justify-end"
              >
                <!-- The whole line, because putting away half of what is on the
                     floor is the exception. Type less to send part of it. -->
                <input
                  type="text"
                  name="quantity"
                  value={quantity(row.quantity)}
                  inputmode="decimal"
                  data-numeric
                  class="input input-sm input-bordered w-20 text-right"
                  aria-label={gettext("How much of %{product} to put in", product: row.product)}
                />
                <button class="btn btn-sm" phx-disable-with={gettext("Storing...")}>
                  {gettext("Put in %{box}", box: @box.code)}
                </button>
              </form>
            </.write_gate>
          </:col>
        </.data_table>
      </.panel>

      <.box_options id="sibling-boxes" boxes={@siblings} />
    </Layouts.app>
    """
  end

  defp do_rebox(socket, target, lot_id, quantity) do
    box = socket.assigns.box
    user_id = socket.assigns.current_scope.user.id

    case Locations.rebox(box, target, lot_id, quantity, user_id: user_id) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{quantity} moved into %{code}.",
             # The raw form value is a string; `quantity/1` formats numbers.
             quantity: quantity(to_decimal(quantity)),
             code: target.code
           )
         )
         |> assign_box(Locations.get_box!(box.id))}

      {:error, {:insufficient_stock, %{available: available}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This box only holds %{available}.", available: quantity(available))
         )}

      {:error, :invalid_quantity} ->
        {:noreply, put_flash(socket, :error, gettext("Type how much to move."))}

      {:error, :same_box} ->
        {:noreply, put_flash(socket, :error, gettext("That is the box it is already in."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The goods could not be moved."))}
    end
  end

  defp verified_label(%{last_verified_at: nil}), do: gettext("never counted")

  defp verified_label(%{last_verified_at: verified_at}) do
    gettext("counted on %{date}", date: date(verified_at))
  end

  @impl true
  def handle_event("stow", %{"lot" => lot_id} = params, socket) do
    %{box: box, current_scope: scope} = socket.assigns

    case Locations.put_in_box(box, lot_id, params["quantity"], user_id: scope.user.id) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> assign_box(Locations.get_box!(box.id))
         |> put_flash(:info, gettext("Stored in %{box}.", box: box.code))}

      {:error, {:insufficient_stock, %{available: available}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("There is only %{available} loose here.", available: quantity(available))
         )}

      {:error, :invalid_quantity} ->
        {:noreply, put_flash(socket, :error, gettext("Type a quantity greater than zero."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That could not be stored."))}
    end
  end

  def handle_event("rebox", %{"lot" => lot_id} = params, socket) do
    rebox(socket, lot_id, params, create: false)
  end

  # The yes. The code and the move riding on it were held rather than written,
  # so this replays the same submission with permission to create.
  def handle_event("confirm_new_box", _params, socket) do
    %{lot_id: lot_id, params: params} = socket.assigns.new_box

    socket
    |> assign(:new_box, nil)
    |> rebox(lot_id, params, create: true)
  end

  def handle_event("cancel_new_box", _params, socket) do
    {:noreply, assign(socket, :new_box, nil)}
  end

  def handle_event("move", %{"location_id" => location_id}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Locations.move_box(socket.assigns.box, location_id, user_id: user_id) do
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
         |> assign_box(moved)}

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

  def handle_event("verify", _params, socket) do
    {:ok, box} = Locations.mark_box_verified(socket.assigns.box)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Box marked as counted today."))
     |> assign_box(Locations.get_box!(box.id))}
  end

  defp rebox(socket, lot_id, params, opts) do
    box = socket.assigns.box

    case Locations.resolve_box(params["box_code"], box.location_id, opts) do
      {:unknown, code} ->
        {:noreply,
         assign(socket, :new_box, %{code: code, lot_id: to_string(lot_id), params: params})}

      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, gettext("Say which box it moves into."))}

      {:ok, target} ->
        do_rebox(socket, target, lot_id, params["quantity"])

      {:created, target} ->
        socket
        |> put_flash(:info, gettext("Box %{code} created here.", code: target.code))
        |> do_rebox(target, lot_id, params["quantity"])

      {:error, {:box_elsewhere, elsewhere}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Box %{code} is somewhere else. Move it first, or use another.",
             code: elsewhere.code
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That box code could not be used."))}
    end
  end
end
