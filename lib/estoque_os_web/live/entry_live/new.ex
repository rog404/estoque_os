defmodule EstoqueOSWeb.EntryLive.New do
  @moduledoc """
  Taking goods into stock that arrived without an invoice.

  Donated toys, a bag somebody handed over at the door. It is real stock and it
  has to be counted, but there is no document and no price — so the ledger
  records no value at all rather than a made-up one, and the screen says R$ 0,01
  where a figure is unavoidable.

  Quantity is in the product's own unit. An invoice says "2 boxes of 100" and
  needs a conversion factor; a person holding the goods counts the things.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.{Catalog, Inventory}

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.Locations

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Finding a product, picking it, saying where it came from: none of that
  writes. `enter` posts the entry, `create_product` adds to the catalog and
  `confirm_new_box` creates a box.
  """
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
     # What is in the form right now, held server-side rather than left to the
     # browser. The screen has to be able to put the entry back on screen —
     # after a refused box code, after a question about creating one — and it
     # cannot do that from values it never kept.
     |> assign(:draft, %{})
     |> assign(:new_box, nil)
     |> assign(:entered, nil)}
  end

  @doc """
  Which stock this entry is for.

  Two ways in, and the role wins both times. The marketing menu links here with
  `?segment=marketing`, which is a convenience for an admin or the coordinator
  — it preselects the stock and narrows the search. For the marketing role
  itself the address is irrelevant: `Scope.segment/1` already answers, and a
  hand-typed `?segment=medical` gets the same answer it would have got with no
  query at all.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:segment, segment(socket, params["segment"]))
     |> assign(:locked_segment, Scope.segment(socket.assigns.current_scope))}
  end

  defp segment(socket, asked) do
    case Scope.segment(socket.assigns.current_scope) do
      nil -> if asked in Product.segments(), do: asked
      forced -> forced
    end
  end

  # Which segment a product created from here is filed under. A screen narrowed
  # to one stock creates into that stock; an unnarrowed one creates into the
  # surgical catalog, which is what 322 of the 322 seeded products are.
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
        <!-- Only for somebody who has both. The marketing role never sees this:
             their stock is the only one they have, and a picker with one option
             is a question with one answer. -->
        <label :if={is_nil(@locked_segment)} class="fieldset">
          <span class="label">{gettext("Stock")}</span>
          <select name="segment" class="select select-bordered">
            <option value="">{gettext("Surgical")}</option>
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

      <!-- Nothing typed yet. The screen used to be a title, one field, and a
           page of white below it, which says nothing about what this flow is
           for — and this is a screen the ONG will be shown. -->
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

      <!-- Creating from here sits *below* the results on purpose. Offered before
           them, it is the fastest path and the catalog fills with the same item
           spelled three ways. -->
      <!-- No `@writable?` guard: this route already requires an operator, so the
           question is settled before the page renders. -->
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
            <!-- A list, not a text field. Typed, one product arrives as UN, the
                 next as Un, a third as UND and a fourth as unidade, and the
                 catalog splits a single item four ways. -->
            <label class="fieldset">
              <span class="label">{gettext("Counted in")}</span>
              <select name="stock_unit" class="select select-bordered w-24">
                <option :for={unit <- Product.stock_units()} value={unit} selected={unit == "UN"}>
                  {unit}
                </option>
              </select>
            </label>
            <.check name="controlled" label={gettext("controlled")} />
            <.check
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

          <!-- `.alert` is a grid, not a flex box, so the `flex-col` this used to
               carry did nothing and the list was dealt into a second column.

               The colour is the sharper half. A nested `bg-base-100` keeps the
               alert's *text* colour while dropping its background, and in the
               light theme `warning-content` is white — so the one thing this
               warning exists to show, the products it found, rendered white on
               white. `text-base-content` is not decoration here; without it the
               list is invisible. Check both themes before touching it. -->
          <div :if={@similar != []} class="alert alert-warning">
            <!-- One child, deliberately. `.alert` lays its children out as grid
                 columns, so the paragraph and the list used to sit side by side
                 with the list crushed against the right edge. Wrapping them
                 makes the alert a one-column grid without fighting daisyUI over
                 specificity. -->
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

          <!-- The first question, because it decides what the rest of the form
               asks and what the ledger is allowed to record. A donation has no
               price and must never be given one; goods bought without an
               invoice have a real price that used to vanish here. -->
          <!-- Two cards rather than two loose radios in a line. This choice
               changes what the rest of the form asks, so it has to read as a
               choice and not as a checkbox somebody might skim past. The whole
               card is the target, which is also the only sane size for it on a
               phone. -->
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

            <label class="fieldset">
              <span class="label">{gettext("Lot")}</span>
              <input
                type="text"
                name="lot_number"
                value={@draft["lot_number"]}
                placeholder={gettext("if it has one")}
                class="input input-bordered w-40"
              />
            </label>

            <label class="fieldset">
              <span class="label">{gettext("Expiry")}</span>
              <input
                type="date"
                name="expires_on"
                value={@draft["expires_on"]}
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

              <!-- Same question the conference asks, in the same place: under
                   the field, not at the top of the page. A code typed one
                   character wrong makes a box that exists, is empty, and is
                   never opened again. -->
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
            <button type="button" phx-click="clear" class="btn btn-ghost">
              {gettext("Choose another product")}
            </button>
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
    socket = assign(socket, :segment, segment(socket, params["segment"]))

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
      # The list this id came from was already filtered, so arriving here means
      # the id was typed rather than clicked. Refused rather than ignored: the
      # screen should say no out loud.
      {:noreply, put_flash(socket, :error, gettext("That product is not in this stock."))}
    else
      pick_product(socket, product)
    end
  end

  # The second submit is the confirmation: the warning listed what it found, and
  # the operator sent the same name back anyway. Nothing to click twice.
  def handle_event("create_product", params, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      stock_unit: blank_to_default(params["stock_unit"], "UN"),
      controlled: params["controlled"] == "true",
      expiry_expected: params["expiry_expected"] == "true",
      lot_expected: params["lot_expected"] == "true",
      segment: segment_for_new_product(socket)
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

  # Fires on every change in the form, not only the two radios. It reveals the
  # price fields when the goods were bought, and it keeps the draft.
  #
  # The draft used to be nobody's job: the comment here said the form "keeps its
  # own values in the DOM", which is true right up until something re-renders
  # the fields — switching to Bought and back, or being asked about a box code.
  # The field said otherwise, so the values are kept where they can be put back.
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

  # The yes. The entry was held rather than posted, so this replays it with
  # permission to create the box.
  def handle_event("confirm_new_box", _params, socket) do
    %{params: params} = socket.assigns.new_box

    socket
    |> assign(:new_box, nil)
    |> resolve_and_enter(params, create: true)
  end

  # The no. Everything typed comes back with the box code cleared, because the
  # box is what was wrong.
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

      # Not a box we know, and a typo here splits the stock into a box nobody
      # will ever open. Same question the conference asks, same answer.
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
         # Spent. The next entry starts blank, or the operator posts the same
         # lot number twice without noticing.
         |> assign(:draft, %{})
         # A box may have just been created by the code that was typed; the
         # next entry should find it in the list.
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

  # Where this belongs, not just which boxes exist. Preselected rather than
  # merely listed: the suggestion is only worth making if it saves the choice.
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
