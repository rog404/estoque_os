defmodule EstoqueOSWeb.KitLive.Show do
  @moduledoc """
  One kit: its components, what the stock covers, and assembling it.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Packing a kit moves stock; choosing a location, checking what a quantity
  would need, and changing your mind about the quantity only report.
  """
  def viewer_events, do: ~w(location review review_again)

  import EstoqueOS.Coercion, only: [to_decimal: 1]

  alias EstoqueOS.Accounts.{Scope, User}
  alias EstoqueOS.Catalog
  alias EstoqueOS.Kits

  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    kit = Kits.get_kit!(id)
    locations = Locations.list_locations()
    location = Locations.default_location() || List.first(locations)

    {:ok,
     socket
     |> assign(:page_title, kit.name)
     |> assign(:kit, kit)
     |> assign(:locations, locations)
     |> assign(:location_id, location && location.id)
     |> assign(:new_box, nil)
     |> load_context()}
  end

  # `review` is the conference: a kit and a quantity typed nowhere else, so
  # any refresh of the kit, the stock, or the location makes it stale and it
  # goes back to nil rather than show a list that no longer matches.
  defp load_context(socket) do
    location_id = socket.assigns.location_id

    socket
    |> assign(:availability, location_id && Kits.availability(socket.assigns.kit, location_id))
    |> assign(:boxes, (location_id && Locations.list_boxes(location_id)) || [])
    |> assign(:assembled_count, Kits.assembled_count(socket.assigns.kit))
    |> assign(:products, Catalog.list_products())
    |> assign(:review, nil)
    |> assign_new(:error, fn -> nil end)
  end

  # After a recipe edit: reload the kit, recompute what the stock covers, and say
  # what happened.
  defp reload(socket, message) do
    socket
    |> assign(:kit, Kits.get_kit!(socket.assigns.kit.id))
    |> assign(:error, nil)
    |> load_context()
    |> put_flash(:info, message)
  end

  # The recipe is a planning decision, not a write one: `roles_that_write()`
  # covers assembly (packing stock into a kit), which logistics does every
  # day, but changing what a kit *is made of* is the narrower `roles_that_plan()`
  # gate — same split ProductLive.Show draws around the minimum.
  defp may_plan?(scope) do
    Scope.effective_role(scope) in User.roles_that_plan()
  end

  defp plan_block(scope) do
    if may_plan?(scope) do
      EstoqueOSWeb.UserAuth.write_block(scope)
    else
      gettext("Only a manager changes the kit recipe.")
    end
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> List.first()
    |> Kernel.||(gettext("That change could not be saved."))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/kits"} back_label={gettext("Kits")}>
        {@kit.name}
        <:subtitle>
          {gettext("%{count} component(s)", count: length(@kit.items))}
          <span :if={@availability}>
            · {gettext("%{possible} kit(s) possible here",
              possible: quantity(@availability.possible)
            )}
          </span>
        </:subtitle>
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

      <div :if={@availability && @availability.unresolved != []} class="alert alert-warning mt-4">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          {gettext(
            "%{count} component(s) are not linked to a catalog product, so this kit cannot be assembled yet.",
            count: length(@availability.unresolved)
          )}
        </span>
      </div>

      <div class="mt-6">
        <.write_gate may={@role_may_write?} allowed={@writable?} reason={@write_block}>
          <div :if={is_nil(@review)} class="panel">
            <form id="review-form" phx-submit="review" class="panel-body space-y-3">
              <h2 class="font-semibold">{gettext("Assemble kits")}</h2>
              <p class="text-sm opacity-70">
                {gettext("Components leave stock for good, and the kit takes their place.")}
              </p>
              <div class="field-row">
                <label class="fieldset">
                  <span class="label">{gettext("How many")}</span>
                  <input
                    type="text"
                    name="quantity"
                    value="1"
                    inputmode="numeric"
                    class="input input-bordered w-24"
                    aria-label={gettext("Number of kits")}
                  />
                </label>
                <.button phx-disable-with={gettext("Checking...")}>{gettext("Check")}</.button>
              </div>
            </form>
          </div>

          <div :if={@review} class="panel">
            <div class="panel-body space-y-3">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="font-semibold">
                  {gettext("%{quantity} kit(s) — what it takes",
                    quantity: quantity(@review.quantity)
                  )}
                </h2>
                <button type="button" phx-click="review_again" class="btn btn-ghost btn-sm">
                  {gettext("Change quantity")}
                </button>
              </div>

              <div :if={@review.expired != []} class="alert alert-error" role="alert">
                <.icon name="hero-exclamation-triangle" class="size-6 shrink-0" />
                <div>
                  <p class="font-semibold">
                    {gettext("Cannot assemble: %{count} component(s) have expired stock here.",
                      count: length(@review.expired)
                    )}
                  </p>
                  <p>
                    {gettext(
                      "A kit is sealed — once an expired item is inside one, nobody opens it to read the date. Write the expired stock off first, then assemble."
                    )}
                  </p>
                </div>
              </div>

              <.data_table rows={@review.lines} row_id={&"review-#{&1.item.id}"}>
                <:col :let={line} label={gettext("Component")} emphasis={:identity}>
                  {line.item.description}
                </:col>
                <:col :let={line} label={gettext("Needed")} align={:right}>
                  <span class={line.short? && "text-error"}>{quantity(line.needed)}</span>
                </:col>
                <:col :let={line} label={gettext("Available here")} align={:right}>
                  {quantity(line.available)}
                </:col>
                <!-- Always rendered, `invisible` when there is nothing to say:
                     a cell that appears only on the offending rows changes the
                     height of those rows, and this list is read with a thumb
                     already on the next one. -->
                <:col :let={line} label={gettext("Expired here")} align={:right}>
                  <span class={["text-error", is_nil(line.expired) && "invisible"]}>
                    {quantity((line.expired || %{quantity: 0}).quantity)}
                    <span class="block text-xs opacity-80">
                      {date((line.expired || %{earliest_expiry: nil}).earliest_expiry)}
                    </span>
                  </span>
                </:col>
                <:col :let={line} label={gettext("Boxes")}>
                  <p>{box_list(line.boxes)}</p>
                </:col>
              </.data_table>

              <form id="assemble-form" phx-submit="assemble" class="field-row">
                <label class="fieldset">
                  <span class="label">{gettext("Into box")}</span>
                  <.box_options id="kit-boxes" boxes={@boxes} />
                  <.box_picker
                    name="box_code"
                    boxes={@boxes}
                    list_id="kit-boxes"
                    value={default_box_code(@boxes)}
                    label={gettext("Box to assemble into")}
                  />
                </label>
                <.button
                  disabled={@review.expired != []}
                  title={
                    @review.expired != [] &&
                      gettext("Write the expired stock off before assembling.")
                  }
                  phx-disable-with={gettext("Assembling...")}
                >
                  {gettext("Assemble")}
                </.button>

                <!-- Supply turns up in instalments. Waiting for the slowest
                     supplier means the assembly gets done the night before a
                     flight. -->
                <.check
                  name="allow_partial"
                  label={gettext("Assemble what has arrived, and note what is missing")}
                />
              </form>

              <.new_box_confirm :if={@new_box} code={@new_box.code} />
            </div>
          </div>
        </.write_gate>
      </div>

      <!-- Editing the recipe reaches into no box: what is inside one is whatever
           the ledger says was moved there. What changes is what the box's label
           means, so the count is said out loud rather than the change being
           refused. A recipe that cannot be corrected goes stale. -->
      <p :if={@role_may_write? and @assembled_count > 0} class="alert alert-info mt-6">
        {gettext(
          "%{count} kit(s) already assembled are in stock. Editing the recipe does not touch them.",
          count: @assembled_count
        )}
      </p>

      <.write_gate
        may={@role_may_write? and may_plan?(@current_scope)}
        allowed={@writable?}
        reason={plan_block(@current_scope)}
      >
        <form
          id="add-item"
          phx-submit="add_item"
          class="field-row mt-4"
        >
          <!-- The product *is* the component. Asking for a free-text name beside
               it, with the product optional and a "link later" escape, is exactly
               how a recipe fills with lines nothing can be assembled from. The
               description comes from the product now. -->
          <label class="fieldset grow min-w-72">
            <span class="label">{gettext("Add a component")}</span>
            <input
              type="text"
              name="product_name"
              list="kit-products"
              placeholder={gettext("Avental EG")}
              class="input input-bordered w-full"
              autocomplete="off"
              required
            />
            <datalist id="kit-products">
              <option :for={product <- @products} value={product.name}></option>
            </datalist>
          </label>
          <label class="fieldset">
            <span class="label">{gettext("Per kit")}</span>
            <input
              type="text"
              name="quantity"
              inputmode="decimal"
              data-numeric
              value="1"
              class="input input-bordered w-20 text-right"
              required
            />
          </label>
          <.button>{gettext("Add")}</.button>
        </form>
      </.write_gate>

      <p :if={@error} class="alert alert-error mt-3">{@error}</p>

      <.panel title={gettext("Recipe")} flush>
        <.data_table rows={@kit.items} row_id={&"item-#{&1.id}"}>
          <:empty>
            <.empty
              title={gettext("This kit has no components yet.")}
              note={
                gettext(
                  "Add what a single kit is made of, and the system can say how many are possible."
                )
              }
            />
          </:empty>

          <:col :let={item} label={gettext("Component")} emphasis={:identity}>
            {item.description}
          </:col>

          <:col :let={item} label={gettext("Product")}>
            <span :if={item.product}>{item.product.name}</span>
            <.status :if={is_nil(item.product)} kind={:not_linked} />
          </:col>

          <:col :let={item} label={gettext("Per kit")} align={:right}>
            {quantity(item.quantity)}
          </:col>

          <:col :let={item} label={gettext("In stock")} align={:right}>
            {available_for(@availability, item)}
          </:col>

          <:col :let={item} label={gettext("Covers")} align={:right} emphasis={:primary}>
            {possible_for(@availability, item)}
          </:col>

          <!-- One actions column rather than an Edit column and a Remove column. Two
               headers for two verbs made the recipe read as a form with a table
               attached; the quantity and the two things you can do to it belong
               to the row, not to columns of their own. Icons carry them, and the
               words survive as the accessible name and the tooltip. -->
          <:col :let={item} label={gettext("Actions")} hide_label_on_card={true} field={:inline} group>
            <div class="flex items-center justify-end gap-1">
              <form phx-submit="update_item" phx-value-id={item.id} class="flex items-center gap-1">
                <input
                  type="text"
                  name="quantity"
                  value={quantity(item.quantity)}
                  inputmode="decimal"
                  disabled={not may_plan?(@current_scope) or not @writable?}
                  title={plan_block(@current_scope)}
                  class="input input-sm w-20 text-right"
                  aria-label={gettext("Quantity per kit for %{item}", item: item.description)}
                />
                <button
                  class="btn btn-success btn-soft btn-square btn-sm"
                  disabled={not may_plan?(@current_scope) or not @writable?}
                  title={plan_block(@current_scope) || gettext("Save")}
                  aria-label={gettext("Save %{item}", item: item.description)}
                >
                  <.icon name="hero-check" class="size-4" />
                </button>
              </form>

              <form id={"remove-form-#{item.id}"} phx-submit="remove_item" class="hidden">
                <input type="hidden" name="item_id" value={item.id} />
              </form>
              <.commit_action
                id={"remove-item-#{item.id}"}
                form={"remove-form-#{item.id}"}
                icon="hero-trash"
                label={gettext("Remove %{item}", item: item.description)}
                title={gettext("Remove %{item} from the recipe?", item: item.description)}
                confirm_label={gettext("Remove")}
                tone={:danger}
                disabled={not may_plan?(@current_scope) or not @writable?}
                reason={plan_block(@current_scope)}
              >
                <:consequence>
                  <p>
                    {gettext("The kit will no longer list it. Kits already assembled do not change.")}
                  </p>
                </:consequence>
              </.commit_action>
            </div>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp line_for(nil, _item), do: nil

  defp line_for(availability, item) do
    Enum.find(availability.lines, &(&1.item.id == item.id))
  end

  # Built fewer than asked for — a success worth naming differently: kits
  # exist now, and the message says what stopped the rest rather than
  # pretending the request was met in full.
  defp handle_assembly({:ok, %{requested: requested, quantity: built, bottleneck: item}}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Assembled %{built} of %{requested}, short on %{item}.",
         built: quantity(built),
         requested: quantity(requested),
         item: item.description
       )
     )
     |> reload_after_assembly()}
  end

  defp handle_assembly({:ok, _result}, socket) do
    {:noreply, socket |> put_flash(:info, gettext("Kits assembled.")) |> reload_after_assembly()}
  end

  defp handle_assembly({:error, :nothing_available}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Nothing here to assemble it from.")
     )}
  end

  defp handle_assembly(other, socket), do: handle_result(other, socket)

  defp reload_after_assembly(socket) do
    socket
    |> assign(:kit, Kits.get_kit!(socket.assigns.kit.id))
    |> load_context()
  end

  defp available_for(availability, item) do
    case line_for(availability, item) do
      nil -> "—"
      line -> quantity(line.available)
    end
  end

  defp possible_for(availability, item) do
    case line_for(availability, item) do
      nil -> "—"
      line -> quantity(line.possible)
    end
  end

  defp box_list([]), do: gettext("nowhere at this location")

  defp box_list(boxes) do
    Enum.map_join(boxes, " · ", fn
      %{box_code: nil, quantity: qty} -> gettext("loose: %{qty}", qty: quantity(qty))
      %{box_code: code, quantity: qty} -> "#{code} (#{quantity(qty)})"
    end)
  end

  # One row per resolved component: how much `quantity` kits need, how much is
  # at the location in total, and which boxes to go stand at for it.
  defp build_review(socket, quantity, params) do
    %{availability: availability, kit: kit, location_id: location_id} = socket.assigns
    breakdown = Kits.box_breakdown(kit, location_id)
    lines = Kits.review_lines(availability, quantity, breakdown)

    %{
      quantity: quantity,
      allow_partial: params["allow_partial"] == "true",
      lines: lines,
      expired: Enum.filter(lines, & &1.expired)
    }
  end

  @impl true
  def handle_event("add_item", params, socket) do
    if may_plan?(socket.assigns.current_scope) do
      do_add_item(params, socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Only a manager changes the kit recipe."))}
    end
  end

  def handle_event("update_item", %{"id" => id, "quantity" => quantity}, socket) do
    cond do
      not may_plan?(socket.assigns.current_scope) ->
        {:noreply, put_flash(socket, :error, gettext("Only a manager changes the kit recipe."))}

      is_nil(kit_item(socket, id)) ->
        {:noreply, assign(socket, :error, gettext("That component is not in this kit."))}

      true ->
        item = kit_item(socket, id)

        case Kits.update_kit_item(item, %{quantity: to_decimal(quantity)}) do
          {:ok, _item} -> {:noreply, reload(socket, gettext("Component updated."))}
          {:error, changeset} -> {:noreply, assign(socket, :error, first_error(changeset))}
        end
    end
  end

  def handle_event("remove_item", %{"item_id" => id}, socket) do
    cond do
      not may_plan?(socket.assigns.current_scope) ->
        {:noreply, put_flash(socket, :error, gettext("Only a manager changes the kit recipe."))}

      is_nil(kit_item(socket, id)) ->
        {:noreply, assign(socket, :error, gettext("That component is not in this kit."))}

      true ->
        {:ok, item} = kit_item(socket, id) |> Kits.remove_kit_item()

        {:noreply,
         reload(socket, gettext("%{item} removed from the recipe.", item: item.description))}
    end
  end

  def handle_event("location", %{"location_id" => location_id}, socket) do
    {:noreply,
     socket
     |> assign(:location_id, String.to_integer(location_id))
     |> load_context()}
  end

  def handle_event("review", %{"quantity" => quantity} = params, socket) do
    with %Decimal{} = q <- to_decimal(quantity),
         :gt <- Decimal.compare(q, 0) do
      {:noreply, assign(socket, :review, build_review(socket, q, params))}
    else
      _invalid -> {:noreply, put_flash(socket, :error, gettext("Type how many kits."))}
    end
  end

  def handle_event("review_again", _params, socket) do
    {:noreply, assign(socket, :review, nil)}
  end

  def handle_event("assemble", params, socket) do
    case socket.assigns.review do
      %{quantity: quantity} -> assemble(socket, quantity, params, create: false)
      nil -> {:noreply, socket}
    end
  end

  # The yes. The code and the assembly riding on it were held rather than
  # written, so this replays the same submission with permission to create.
  def handle_event("confirm_new_box", _params, socket) do
    %{quantity: quantity, params: params} = socket.assigns.new_box

    socket
    |> assign(:new_box, nil)
    |> assemble(quantity, params, create: true)
  end

  def handle_event("cancel_new_box", _params, socket) do
    {:noreply, assign(socket, :new_box, nil)}
  end

  defp do_add_item(params, socket) do
    name = String.trim(params["product_name"] || "")

    case Enum.find(socket.assigns.products, &(&1.name == name)) do
      nil ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext(
             "%{name} is not in the catalog. A kit can only ask for something the stock knows about.",
             name: name
           )
         )}

      product ->
        attrs = %{
          # The name the catalog uses, not one somebody retyped beside it.
          description: product.name,
          quantity: to_decimal(params["quantity"]),
          product_id: product.id
        }

        case Kits.add_kit_item(socket.assigns.kit, attrs) do
          {:ok, _item} ->
            {:noreply, reload(socket, gettext("Component added."))}

          {:error, :already_a_component} ->
            {:noreply,
             assign(
               socket,
               :error,
               gettext("%{name} is already in this kit. Change how many it needs instead.",
                 name: product.name
               )
             )}

          {:error, changeset} ->
            {:noreply, assign(socket, :error, first_error(changeset))}
        end
    end
  end

  # Only the item belonging to the kit loaded in this socket, never another
  # kit's — the id/item_id in the event params comes straight from the client.
  defp kit_item(socket, id) do
    item_id = String.to_integer(id)
    Enum.find(socket.assigns.kit.items, &(&1.id == item_id))
  end

  defp build(socket, quantity, box, params) do
    socket.assigns.kit
    |> Kits.assemble(quantity, %{
      location_id: socket.assigns.location_id,
      box_id: box.id,
      user_id: socket.assigns.current_scope.user.id,
      allow_partial: params["allow_partial"] == "true"
    })
    |> handle_assembly(socket)
  end

  defp default_box_code([box | _rest]), do: box.code
  defp default_box_code(_none), do: nil

  defp handle_result({:error, {:insufficient_stock, %{item: item, missing: missing}}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Not enough %{item}: %{missing} missing.",
         item: item.description,
         missing: quantity(missing)
       )
     )}
  end

  # Not a warning: assembly is refused. Naming the component and the date is
  # what makes the next step obvious, because the next step is to write that
  # stock off and try again.
  defp handle_result({:error, {:expired_components, lines}}, socket) do
    first = List.first(lines)

    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "%{count} component(s) have expired stock here, starting with %{item}, expired since %{date}. Write the expired stock off first — a kit is sealed, and nobody opens one to read a date.",
         count: length(lines),
         item: first.item.description,
         date: date(first.expired.earliest_expiry)
       )
     )}
  end

  defp handle_result({:error, {:unresolved_items, items}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("%{count} component(s) still need a product.", count: length(items))
     )}
  end

  defp handle_result({:error, :invalid_quantity}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Type how many kits."))}
  end

  defp handle_result({:error, _reason}, socket) do
    {:noreply, put_flash(socket, :error, gettext("The operation could not be completed."))}
  end

  defp assemble(socket, quantity, params, opts) do
    case Locations.resolve_box(params["box_code"], socket.assigns.location_id, opts) do
      {:unknown, code} ->
        {:noreply, assign(socket, :new_box, %{code: code, quantity: quantity, params: params})}

      {:ok, nil} ->
        {:noreply,
         put_flash(socket, :error, gettext("Say which box the kits are assembled into."))}

      {:ok, box} ->
        build(socket, quantity, box, params)

      {:created, box} ->
        socket
        |> put_flash(:info, gettext("Box %{code} created here.", code: box.code))
        |> build(quantity, box, params)

      {:error, {:box_elsewhere, box}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Box %{code} is somewhere else. Move it first, or use another.",
             code: box.code
           )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That box code could not be used."))}
    end
  end
end
