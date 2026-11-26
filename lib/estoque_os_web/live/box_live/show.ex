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
    # Re-boxing is within one room; elsewhere is a location move, a different act.
    |> assign(:siblings, Enum.reject(Locations.list_boxes(box.location_id), &(&1.id == box.id)))
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
            <.button navigate={~p"/boxes/#{@box}/count"} variant="primary" class="btn-sm">
              {gettext("Count this box")}
            </.button>
            <.button phx-click="verify" class="btn-sm">
              {gettext("Mark as counted")}
            </.button>

            <form id="move-form" phx-submit="move" class="flex items-center gap-2">
              <%!-- As in the Boxes listing: mission and transit are reached only by load-out. --%>
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
              <.button class="btn-sm" phx-disable-with={gettext("Moving...")}>
                {gettext("Carry the box there")}
              </.button>
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
                <.button class="btn-sm" phx-disable-with={gettext("Moving...")}>
                  {gettext("Move")}
                </.button>

                <%!-- Deliberate exception to "always render, never :if": this banner is a decision to answer before anything else and holds the next tap inside itself; reserving its height in every row would leave a table of blank space. --%>
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
                <input
                  type="text"
                  name="quantity"
                  value={quantity(row.quantity)}
                  inputmode="decimal"
                  data-numeric
                  class="input input-sm input-bordered w-20 text-right"
                  aria-label={gettext("How much of %{product} to put in", product: row.product)}
                />
                <.button class="btn-sm" phx-disable-with={gettext("Storing...")}>
                  {gettext("Put in %{box}", box: @box.code)}
                </.button>
              </form>
            </.write_gate>
          </:col>
        </.data_table>
      </.panel>

      <.panel :if={@role_may_write?} title={gettext("Tidy the box")} flush>
        <div class="flex flex-col gap-6 p-4">
          <div :if={not @box.active} class="alert alert-warning text-sm">
            {gettext("This box is retired: it is hidden from listings and pickers.")}
          </div>

          <.write_gate
            :if={@contents != [] and @siblings != []}
            may={true}
            allowed={@controls_enabled?}
          >
            <form id="empty-box-form" phx-submit="empty_box" class="flex flex-wrap items-end gap-2">
              <div class="flex flex-col gap-1">
                <span class="text-sm font-medium">{gettext("Empty this box into another")}</span>
                <.box_picker
                  name="box_code"
                  boxes={@siblings}
                  list_id="sibling-boxes"
                  label={gettext("Box to move everything into")}
                />
              </div>
              <.button class="btn-sm" phx-disable-with={gettext("Moving...")}>
                {gettext("Move everything")}
              </.button>
            </form>
          </.write_gate>

          <.write_gate may={true} allowed={@controls_enabled?}>
            <form id="rename-box-form" phx-submit="rename" class="flex flex-wrap items-end gap-2">
              <div class="flex flex-col gap-1">
                <span class="text-sm font-medium">{gettext("Rename this box")}</span>
                <input
                  type="text"
                  name="code"
                  value={@box.code}
                  class="input input-sm input-bordered w-32"
                  aria-label={gettext("New box code")}
                />
              </div>
              <.button class="btn-sm" phx-disable-with={gettext("Renaming...")}>
                {gettext("Rename")}
              </.button>
            </form>
          </.write_gate>

          <.write_gate may={true} allowed={@controls_enabled?}>
            <div class="flex flex-wrap items-center gap-2">
              <.button
                :if={@box.active}
                phx-click="retire"
                class="btn-sm btn-outline"
                disabled={@contents != []}
              >
                {gettext("Retire this box")}
              </.button>
              <span :if={@box.active and @contents != []} class="text-sm text-base-content/60">
                {gettext("Empty it first.")}
              </span>
              <.button :if={not @box.active} phx-click="reopen" class="btn-sm">
                {gettext("Reopen this box")}
              </.button>
            </div>
          </.write_gate>
        </div>
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

  # Replays the held submission with permission to create the box.
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

  def handle_event("empty_box", %{"box_code" => code}, socket) do
    box = socket.assigns.box

    case Locations.resolve_box(code, box.location_id, create: false) do
      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, gettext("Say which box to empty it into."))}

      {:ok, target} ->
        do_empty(socket, target)

      {:unknown, _code} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No box here wears that code. Create it on the Boxes screen first.")
         )}

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

  def handle_event("rename", %{"code" => code}, socket) do
    case Locations.rename_box(socket.assigns.box, code) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> assign(:page_title, gettext("Box %{code}", code: renamed.code))
         |> put_flash(:info, gettext("Box renamed to %{code}.", code: renamed.code))
         |> assign_box(Locations.get_box!(renamed.id))}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, rename_error(changeset))}
    end
  end

  def handle_event("retire", _params, socket) do
    box = socket.assigns.box

    case Locations.retire_box(box) do
      {:ok, retired} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Box %{code} retired.", code: retired.code))
         |> assign_box(Locations.get_box!(retired.id))}

      {:error, :not_empty} ->
        {:noreply, put_flash(socket, :error, gettext("Empty the box before retiring it."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The box could not be retired."))}
    end
  end

  def handle_event("reopen", _params, socket) do
    {:ok, reopened} = Locations.reopen_box(socket.assigns.box)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Box %{code} reopened.", code: reopened.code))
     |> assign_box(Locations.get_box!(reopened.id))}
  end

  defp do_empty(socket, target) do
    box = socket.assigns.box
    user_id = socket.assigns.current_scope.user.id

    case Locations.empty_box_into(box, target, user_id: user_id) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Everything moved into %{code}.", code: target.code))
         |> assign_box(Locations.get_box!(box.id))}

      {:error, :same_box} ->
        {:noreply, put_flash(socket, :error, gettext("That is this very box."))}

      {:error, :empty_box} ->
        {:noreply, put_flash(socket, :error, gettext("This box is already empty."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The goods could not be moved."))}
    end
  end

  # The box code is required and unique; say which rule the typed code broke.
  defp rename_error(%Ecto.Changeset{errors: errors}) do
    case errors[:code] do
      {_message, opts} ->
        if opts[:constraint] == :unique do
          gettext("Another box already uses that code.")
        else
          gettext("Type a code for the box.")
        end

      _ ->
        gettext("The box could not be renamed.")
    end
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
