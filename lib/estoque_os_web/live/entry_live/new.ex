defmodule EstoqueOSWeb.EntryLive.New do
  @moduledoc """
  Taking goods into stock that arrived without an invoice (donations, a bag at
  the door). No document and no price, so the ledger records no value rather
  than a made-up one. Quantity is in the product's own unit, with no conversion
  factor.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.{Catalog, Inventory}

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.Locations

  # Events a viewer may send; everything else is refused. `enter`,
  # `create_product` and `confirm_new_box` write and are excluded.
  def viewer_events, do: ~w(search pick origin clear cancel_new_box)

  @impl true
  def mount(_params, _session, socket) do
    locations = Locations.list_locations()
    location = Locations.default_location() || List.first(locations)

    {:ok,
     socket
     |> assign(:page_title, gettext("Manual entry"))
     |> assign(:locations, locations)
     |> assign(:location_id, location && location.id)
     |> assign(:boxes, boxes_for(location))
     |> assign(:query, "")
     |> assign(:products, [])
     |> assign(:product, nil)
     |> assign(:similar, [])
     |> assign(:new_product_name, nil)
     |> assign(:expiry_expected, true)
     |> assign(:lot_expected, true)
     |> assign(:suggestions, [])
     |> assign(:origin, "donation")
     # Form values held server-side so a re-render (refused box code, new-box
     # question) can put the entry back.
     |> assign(:draft, %{})
     |> assign(:new_box, nil)
     |> assign(:entered, nil)}
  end

  # The role wins over `?segment=`: it only preselects the stock for an admin or
  # coordinator, and `Scope.segment/2` answers for a marketing user whatever the
  # address says.
  @impl true
  def handle_params(params, _uri, socket) do
    segment = segment(socket, params["segment"])

    {:noreply,
     socket
     |> assign(:segment, segment)
     |> preselect_location(segment)}
  end

  # The two stocks come in through different doors, so the location follows the
  # stock. Only on the way in: once open, the location is the operator's to change.
  defp preselect_location(socket, segment) do
    location = Locations.default_location(segment) || List.first(socket.assigns.locations)

    socket
    |> assign(:location_id, location && location.id)
    |> assign(:boxes, boxes_for(location))
  end

  defp segment(socket, asked), do: Scope.segment(socket.assigns.current_scope, asked)

  # A narrowed screen creates into its stock; otherwise into the surgical catalog.
  defp segment_for_new_product(socket), do: socket.assigns.segment || "medical"

  defp pick_product(socket, product) do
    {:noreply,
     socket
     |> assign(:product, product)
     |> assign(:products, [])
     |> assign(:similar, [])
     |> assign(:entered, nil)
     |> assign_suggestions(product)}
  end

  defp boxes_for(nil), do: []
  defp boxes_for(location), do: Locations.list_boxes(location.id)

  defp boxes_at(nil), do: []
  defp boxes_at(location_id), do: Locations.list_boxes(location_id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Manual entry")}
        <:subtitle>
          {gettext("Goods that arrived without an invoice — a donation received at the door.")}
        </:subtitle>
      </.header>

      <div :if={@entered} class="alert alert-success mt-4">
        {gettext("%{quantity} × %{product} taken into stock.",
          quantity: quantity(@entered.quantity),
          product: @entered.product
        )}
      </div>

      <form id="search-form" phx-change="search" class="field-row mt-4">
        <label class="fieldset grow min-w-72">
          <span class="label">{gettext("Product")}</span>
          <input
            type="search"
            name="query"
            value={@query}
            placeholder={gettext("Search the catalog by name")}
            class="input input-bordered w-full"
            phx-debounce="300"
          />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Stock")}</span>
          <select name="segment" class="select select-bordered">
            <option value="medical" selected={@segment != "marketing"}>
              {gettext("Surgical")}
            </option>
            <option value="marketing" selected={@segment == "marketing"}>
              {gettext("Marketing")}
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Into")}</span>
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

      <.panel :if={@query == "" and is_nil(@product)}>
        <.empty
          title={gettext("Start by finding the product.")}
          note={
            gettext(
              "Type what is written on the box. If the catalog does not have it yet, you can create it from here — donations often arrive as something new."
            )
          }
        />
      </.panel>

      <ul
        :if={@products != [] and is_nil(@product)}
        class="menu bg-base-100 rounded-box mt-3 w-full border border-base-300"
      >
        <li :for={result <- @products}>
          <button type="button" phx-click="pick" phx-value-product={result.product.id}>
            {result.product.name}
            <.status :if={result.product.controlled} kind={:controlled} />
          </button>
        </li>
      </ul>

      <%!-- Creating sits below the results on purpose: offered first, the catalog fills with one item spelled three ways. No `@writable?` guard: the route already requires an operator. --%>
      <div
        :if={@query != "" and is_nil(@product)}
        class="panel"
      >
        <div class="panel-body space-y-3">
          <p :if={@products == []} class="opacity-70">
            {gettext("Nothing in the catalog matches that.")}
          </p>
          <p :if={@products != []} class="opacity-70">
            {gettext("None of these? Something that arrived by donation may be new.")}
          </p>

          <form id="new-product" phx-submit="create_product" class="field-row">
            <label class="fieldset grow min-w-64">
              <span class="label">{gettext("New product name")}</span>
              <input
                type="text"
                name="name"
                value={@new_product_name || @query}
                class="input input-bordered w-full"
                required
              />
            </label>
            <%!-- A list, not free text, so one unit is not spelled four ways. --%>
            <label class="fieldset">
              <span class="label">{gettext("Counted in")}</span>
              <select name="stock_unit" class="select select-bordered w-24">
                <option :for={unit <- Product.stock_units()} value={unit} selected={unit == "UN"}>
                  {unit}
                </option>
              </select>
            </label>
            <%!-- Not asked for the marketing stock: the answer is always no. --%>
            <.check :if={@segment != "marketing"} name="controlled" label={gettext("controlled")} />
            <.check
              :if={@segment != "marketing"}
              name="expiry_expected"
              label={gettext("has an expiry date")}
              checked={@expiry_expected}
            />
            <.check
              name="lot_expected"
              label={gettext("has a lot number")}
              checked={@lot_expected}
            />
            <.button variant="primary">
              {if @similar == [],
                do: gettext("Create and use"),
                else: gettext("Create anyway")}
            </.button>
          </form>

          <%!-- `.alert` is a grid: one child keeps it one column. The nested `bg-base-100` list needs `text-base-content`, or warning-content is white on white in the light theme. --%>
          <div :if={@similar != []} class="alert alert-warning">
            <div class="w-full space-y-2 text-left">
              <p>
                {gettext(
                  "The catalog already has something very close. Picking one of these keeps the count in one place."
                )}
              </p>
              <ul class="menu bg-base-100 text-base-content rounded-box w-full p-1">
                <li :for={match <- @similar}>
                  <button type="button" phx-click="pick" phx-value-product={match.product.id}>
                    {match.product.name}
                    <.status :if={match.product.controlled} kind={:controlled} />
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>

      <form
        :if={@product}
        id="entry-form"
        phx-submit="enter"
        phx-change="origin"
        class="panel"
      >
        <div class="panel-body space-y-3">
          <h2 class="font-semibold">
            {@product.name}
            <.status :if={@product.controlled} kind={:controlled} />
          </h2>

          <%!-- First question: it decides what the form asks and what the ledger may record (a donation never gets a price). Whole-card targets for phones. --%>
          <fieldset class="grid sm:grid-cols-2 gap-2">
            <legend class="label">{gettext("How it arrived")}</legend>
            <label class={[
              "flex items-start gap-3 rounded-box border p-3 cursor-pointer",
              if(@origin == "donation",
                do: "border-primary bg-primary/5",
                else: "border-base-300 hover:border-base-content/30"
              )
            ]}>
              <input
                type="radio"
                name="origin"
                value="donation"
                checked={@origin == "donation"}
                class="radio radio-sm mt-0.5"
              />
              <span>
                <span class="block font-medium">{gettext("Donation")}</span>
                <span class="block text-xs opacity-70">
                  {gettext("No price is recorded, ever.")}
                </span>
              </span>
            </label>
            <label class={[
              "flex items-start gap-3 rounded-box border p-3 cursor-pointer",
              if(@origin == "purchase",
                do: "border-primary bg-primary/5",
                else: "border-base-300 hover:border-base-content/30"
              )
            ]}>
              <input
                type="radio"
                name="origin"
                value="purchase"
                checked={@origin == "purchase"}
                class="radio radio-sm mt-0.5"
              />
              <span>
                <span class="block font-medium">{gettext("Bought")}</span>
                <span class="block text-xs opacity-70">
                  {gettext("Bought without an invoice, and it cost something.")}
                </span>
              </span>
            </label>
          </fieldset>

          <p :if={@origin == "donation"} class="text-sm text-base-content/70">
            {gettext("Counted in %{unit}. No value is recorded; documents declare %{value}.",
              unit: @product.stock_unit,
              value: declared_money(nil)
            )}
          </p>

          <div :if={@origin == "purchase"} class="field-row">
            <label class="fieldset">
              <span class="label">{gettext("Unit price")}</span>
              <input
                type="text"
                name="unit_cost"
                value={@draft["unit_cost"]}
                inputmode="decimal"
                placeholder={gettext("per %{unit}", unit: @product.stock_unit)}
                class="input input-bordered w-32"
              />
            </label>
            <label class="fieldset">
              <span class="label">{gettext("Total paid")}</span>
              <input
                type="text"
                name="total_cost"
                value={@draft["total_cost"]}
                inputmode="decimal"
                placeholder={gettext("if that is what the receipt says")}
                class="input input-bordered w-32"
              />
            </label>
            <p class="text-sm text-base-content/70 basis-full">
              {gettext(
                "Either one. A total is divided by the quantity that actually arrived; leave both blank and the goods enter with no value on record."
              )}
            </p>
          </div>

          <div class="field-row">
            <label class="fieldset">
              <span class="label">{gettext("Quantity")}</span>
              <input
                type="text"
                name="quantity"
                value={@draft["quantity"]}
                inputmode="decimal"
                class="input input-bordered w-28"
                aria-label={gettext("Quantity received")}
                phx-mounted={JS.focus()}
              />
            </label>

            <%!-- Lot and expiry are disabled, not hidden, when `lot_expected` / `expiry_expected` are false, so the row keeps its shape. --%>
            <label class="fieldset">
              <span class="label">{gettext("Lot")}</span>
              <input
                type="text"
                name="lot_number"
                value={@draft["lot_number"]}
                placeholder={
                  if(@product.lot_expected, do: gettext("if it has one"), else: gettext("has none"))
                }
                disabled={not @product.lot_expected}
                title={unless @product.lot_expected, do: gettext("This product has no lot number.")}
                class="input input-bordered w-40"
              />
            </label>

            <label class="fieldset">
              <span class="label">{gettext("Expiry")}</span>
              <input
                type="date"
                name="expires_on"
                value={@draft["expires_on"]}
                disabled={not @product.expiry_expected}
                title={
                  unless @product.expiry_expected, do: gettext("This product has no expiry date.")
                }
                class="input input-bordered"
              />
            </label>

            <label class="fieldset">
              <span class="label">{gettext("Box")}</span>
              <.box_options id="entry-boxes" boxes={@boxes} />
              <.box_picker
                name="box_code"
                boxes={@boxes}
                list_id="entry-boxes"
                value={@draft["box_code"] || suggested_box_code(@suggestions)}
                label={gettext("Box")}
                hint={@suggestions != [] && suggestion_reason(hd(@suggestions))}
              />

              <.new_box_confirm :if={@new_box} code={@new_box.code} class="mt-2" />
            </label>
          </div>

          <label class="fieldset">
            <span class="label">{gettext("Note")}</span>
            <input
              type="text"
              name="notes"
              value={@draft["notes"]}
              placeholder={gettext("who donated it, for the record")}
              class="input input-bordered w-full"
            />
          </label>

          <p class="text-sm text-base-content/70">
            {gettext(
              "A lot with no number is flagged for review, so nobody mistakes it for a known batch."
            )}
          </p>

          <div class="flex items-center gap-3">
            <.button variant="primary" phx-disable-with={gettext("Recording...")}>
              {gettext("Take into stock")}
            </.button>
            <.button variant="ghost" type="button" phx-click="clear">
              {gettext("Choose another product")}
            </.button>
          </div>
        </div>
      </form>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", params, socket) do
    location_id = parse_id(params["location_id"]) || socket.assigns.location_id
    location = Enum.find(socket.assigns.locations, &(&1.id == location_id))
    query = params["query"] || ""
    # Only when the form carries one: a missing key would fall back to the role's
    # default and undo the stock the address asked for.
    socket =
      case params["segment"] do
        nil -> socket
        asked -> assign(socket, :segment, segment(socket, asked))
      end

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:location_id, location_id)
     |> assign(:boxes, boxes_for(location))
     |> assign(:similar, [])
     |> assign(:new_product_name, nil)
     |> assign(
       :products,
       if(query == "",
         do: [],
         else: Catalog.search_products(query, limit: 8, segment: socket.assigns.segment)
       )
     )}
  end

  def handle_event("pick", %{"product" => product_id}, socket) do
    product = Catalog.get_product!(String.to_integer(product_id))

    if socket.assigns.segment && product.segment != socket.assigns.segment do
      # The list was already filtered, so this id was hand-made: refuse out loud.
      {:noreply, put_flash(socket, :error, gettext("That product is not in this stock."))}
    else
      pick_product(socket, product)
    end
  end

  # The second submit is the confirmation: the operator resent the same name
  # after the similar-products warning.
  def handle_event("create_product", params, socket) do
    segment = segment_for_new_product(socket)

    # Decided from the stock, not the submission: marketing never renders these
    # ticks and a hand-made post must not set them.
    attrs = %{
      name: String.trim(params["name"] || ""),
      stock_unit: blank_to_default(params["stock_unit"], "UN"),
      controlled: segment != "marketing" and params["controlled"] == "true",
      expiry_expected: segment != "marketing" and params["expiry_expected"] == "true",
      lot_expected: params["lot_expected"] == "true",
      segment: segment
    }

    confirmed? = socket.assigns.similar != []

    case Catalog.create_product_checked(attrs, confirmed: confirmed?) do
      {:ok, product} ->
        {:noreply,
         socket
         |> assign(:product, product)
         |> assign(:products, [])
         |> assign(:similar, [])
         |> assign(:new_product_name, nil)
         |> put_flash(:info, gettext("%{name} added to the catalog.", name: product.name))}

      {:error, {:similar, matches}} ->
        {:noreply,
         socket
         |> assign(:similar, matches)
         |> assign(:new_product_name, attrs.name)
         |> assign(:expiry_expected, attrs.expiry_expected)
         |> assign(:lot_expected, attrs.lot_expected)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("That product could not be created."))}
    end
  end

  # Fires on every change in the form: reveals the price fields for a purchase
  # and keeps the draft, since the DOM loses values on re-render.
  def handle_event("origin", params, socket) do
    {:noreply,
     socket
     |> assign(:origin, params["origin"] || socket.assigns.origin)
     |> assign(:draft, Map.merge(socket.assigns.draft, form_draft(params)))}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(:product, nil) |> assign(:query, "") |> assign(:products, [])}
  end

  def handle_event("enter", params, socket) do
    resolve_and_enter(socket, params, create: false)
  end

  # Replays the held entry with permission to create the box.
  def handle_event("confirm_new_box", _params, socket) do
    %{params: params} = socket.assigns.new_box

    socket
    |> assign(:new_box, nil)
    |> resolve_and_enter(params, create: true)
  end

  # Everything typed comes back with the box code cleared.
  def handle_event("cancel_new_box", _params, socket) do
    %{params: params} = socket.assigns.new_box

    {:noreply,
     socket
     |> assign(:new_box, nil)
     |> assign(:draft, params |> form_draft() |> Map.put("box_code", ""))}
  end

  @draft_fields ~w(quantity lot_number expires_on box_code notes unit_cost total_cost)

  defp form_draft(params), do: Map.take(params, @draft_fields)

  defp resolve_and_enter(socket, params, opts) do
    product = socket.assigns.product

    case Locations.resolve_box(params["box_code"], socket.assigns.location_id, opts) do
      {:ok, box} ->
        take_in(socket, product, box, params)

      # A typo here would split the stock into a box nobody opens.
      {:unknown, code} ->
        {:noreply, assign(socket, :new_box, %{code: code, params: params})}

      {:created, box} ->
        socket
        |> put_flash(:info, gettext("Box %{code} created here.", code: box.code))
        |> take_in(product, box, params)

      {:error, {:box_elsewhere, box}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Box %{code} is at %{location}. Move it first, or use another.",
             code: box.code,
             location: box_location_name(box)
           )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That box code could not be used."))}
    end
  end

  defp box_location_name(box) do
    case EstoqueOS.Repo.preload(box, :location) do
      %{location: %{name: name}} -> name
      _other -> "—"
    end
  end

  defp take_in(socket, product, box, params) do
    attrs = %{
      product_id: product.id,
      location_id: socket.assigns.location_id,
      box_id: box && box.id,
      quantity: params["quantity"],
      lot_number: params["lot_number"],
      expires_on: params["expires_on"],
      notes: params["notes"],
      origin: params["origin"],
      unit_cost: params["unit_cost"],
      total_cost: params["total_cost"],
      user_id: socket.assigns.current_scope.user.id
    }

    case Inventory.enter_manually(attrs) do
      {:ok, transaction} ->
        entry = hd(transaction.entries)

        {:noreply,
         socket
         |> assign(:entered, %{product: product.name, quantity: entry.quantity})
         |> assign(:product, nil)
         |> assign(:query, "")
         |> assign(:products, [])
         # Spent: the next entry starts blank so a lot number is not posted twice.
         |> assign(:draft, %{})
         # The typed code may have just created a box.
         |> assign(:boxes, boxes_at(socket.assigns.location_id))}

      {:error, :invalid_quantity} ->
        {:noreply, put_flash(socket, :error, gettext("Say how many arrived."))}

      {:error, :missing_location} ->
        {:noreply, put_flash(socket, :error, gettext("Pick where it goes."))}

      {:error, :box_elsewhere} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That box is not at this location. Move the box first, or pick another.")
         )}

      {:error, :expiry_conflict} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This lot is already on record with a different expiry date. Check the goods before recording."
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That could not be recorded."))}
    end
  end

  defp assign_suggestions(socket, product) do
    case socket.assigns.location_id do
      nil ->
        assign(socket, :suggestions, [])

      location_id ->
        assign(socket, :suggestions, Locations.suggest_boxes(product.id, location_id, limit: 1))
    end
  end

  defp suggested_box_code([%{box: box} | _]), do: box.code
  defp suggested_box_code(_none), do: nil

  defp suggestion_reason(%{reason: :same_product, box: box, because: name}) do
    gettext("%{box} already holds %{product} — one product, one box",
      box: box.code,
      product: name
    )
  end

  defp suggestion_reason(%{reason: :same_group, box: box, because: name}) do
    gettext("%{box} holds %{product}, from the same group", box: box.code, product: name)
  end

  defp suggestion_reason(%{reason: :same_sector, box: box, because: sector}) do
    gettext("%{box} holds %{sector} items", box: box.code, sector: sector)
  end

  defp blank_to_default(value, default) do
    case String.trim(to_string(value)) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, _} -> id
      :error -> nil
    end
  end
end
