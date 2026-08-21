defmodule EstoqueOSWeb.IssueLive.Index do
  @moduledoc """
  Manual issue: someone came and took things.

  Search is by name across the catalog, because the person at the counter
  knows what the thing is called, not which lot it came from — the lot is our
  problem, and FEFO answers it.
  """

  use EstoqueOSWeb, :live_view

  import EstoqueOS.Coercion, only: [to_decimal: 1, to_id: 1, blank_to_nil: 1]

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.{Catalog, Inventory, Outbound}
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Inventory.Transaction

  # One copy of these, in `EstoqueOSWeb.Movement`. This screen and the list of
  # write-offs each had their own, which is how a new destination gets a label
  # on one screen and its raw key on the other.
  import EstoqueOSWeb.Movement, only: [destination_label: 1]

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  The basket lives in the socket until `issue` posts it, so filling it and
  emptying it move nothing. Searching, scanning and previewing the FEFO pick
  are reads.
  """
  def viewer_events, do: ~w(search scan pick destination preview add drop clear_product)

  @impl true
  def mount(_params, _session, socket) do
    locations = Locations.list_locations()
    segment = Scope.segment(socket.assigns.current_scope)
    location = Locations.default_location(segment) || List.first(locations)

    {:ok,
     socket
     |> assign(:page_title, gettext("Write off"))
     |> assign(:locations, locations)
     |> assign(:location_id, location && location.id)
     |> assign(:query, "")
     |> assign(:products, [])
     |> assign(:product, nil)
     |> assign(:box_options, [])
     |> assign(:picks, nil)
     |> assign(:quantity, "")
     |> assign(:sale_unit_price, "")
     |> assign(:destination, nil)
     |> assign(:basket, [])
     |> load_here()}
  end

  # Arrived from a product page, which knows which product and nothing else.
  # The product comes out picked, with the quantity field focused: the person
  # who pressed "Dar baixa" over there was already looking at this product and
  # has no reason to type its name into a search box here.
  #
  # An id that does not resolve is not worth a page about an error — the screen
  # is perfectly usable without it, so it opens as it always does.
  @impl true
  def handle_params(%{"product" => product_id} = params, _uri, socket) do
    socket = assign_segment(socket, params)

    case Integer.parse(product_id) do
      {id, ""} ->
        case Catalog.fetch_product(id) do
          {:ok, product} -> {:noreply, pick_product(socket, product)}
          :error -> {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_params(params, _uri, socket), do: {:noreply, assign_segment(socket, params)}

  # Which stock this screen is about. The marketing menu asks for one in the
  # address; the marketing role has one whatever the address says. Everything
  # that lists a product here — the search, the scanner, "what is here" — passes
  # it down, so the narrowing is a `where` in a query rather than a template
  # that renders fewer rows.
  defp assign_segment(socket, params) do
    segment = Scope.segment(socket.assigns.current_scope, params["segment"])

    socket |> assign(:segment, segment) |> load_here()
  end

  defp load_here(socket) do
    case socket.assigns.location_id do
      nil ->
        assign(socket, :here, [])

      location_id ->
        assign(
          socket,
          :here,
          Inventory.products_at(location_id, segment: socket.assigns[:segment])
        )
    end
  end

  # The basket keeps the name so the list reads without a lookup, and the id so
  # the ledger has something to post against. `box_code` is display only —
  # `box_id` is what actually pins the pick when it is set.
  defp basket_line(product, quantity, box_id, box_code, opts) do
    %{
      product_id: product.id,
      product: product.name,
      quantity: quantity,
      box_id: box_id,
      box_code: box_code,
      sale_unit_price: opts[:sale_unit_price]
    }
  end

  # The stock that is sold. Marketing material leaves with a price on it;
  # surgical supply is consumed or donated, and asking its price on the way out
  # would be asking a question the operation does not have an answer to.
  defp sellable?(%{segment: "marketing"}), do: true
  defp sellable?(_product), do: false

  # Nothing to choose between when the product is all in one place — showing a
  # single-option picker would be a decision with no second option.
  defp box_choice?(box_options), do: length(box_options) > 1

  # The box holding whatever expires first, the same lot FEFO would reach for
  # on its own. Undated stock sorts last: an unknown expiry is not "soonest".
  #
  # `Date` structs compare wrong under the default `<=` sorter — it walks
  # struct fields in key order (`day` before `month` before `year`), not
  # calendar order. ISO 8601 strings sort lexicographically exactly the way
  # dates sort chronologically, so that is the key, not the date itself.
  defp recommended_box(box_options) do
    Enum.min_by(box_options, fn box ->
      {is_nil(box.expires_on), box.expires_on && Date.to_iso8601(box.expires_on)}
    end)
  end

  defp box_label(%{box_code: nil, quantity: qty, expires_on: expires_on}) do
    gettext("loose — %{qty} — expires %{expiry}",
      qty: quantity(qty),
      expiry: expiry_label(expires_on)
    )
  end

  defp box_label(%{box_code: code, quantity: qty, expires_on: expires_on}) do
    gettext("%{box} — %{qty} — expires %{expiry}",
      box: code,
      qty: quantity(qty),
      expiry: expiry_label(expires_on)
    )
  end

  # Just enough to name the recommendation inside the default option — the
  # quantity and expiry are already spelled out on that same box's own line
  # in the list below, and repeating them here is what pushed the option's
  # text past what a native `<select>` shows before cutting it off.
  defp short_box_label(%{box_code: nil}), do: gettext("loose")
  defp short_box_label(%{box_code: code}), do: code

  defp expiry_label(nil), do: gettext("unknown")
  defp expiry_label(%Date{} = expires_on), do: date(expires_on)

  defp pick_product(socket, product) do
    socket
    |> assign(:product, product)
    |> assign(:box_options, Inventory.box_quantities(product.id, socket.assigns.location_id))
    |> assign(:picks, nil)
    |> assign(:quantity, "")
    |> assign(:sale_unit_price, "")
  end

  defp compute_picks(socket, params) do
    with %Decimal{} = amount <- to_decimal(params["quantity"]),
         :gt <- Decimal.compare(amount, 0) do
      box_id = to_id(params["box_id"])

      case Inventory.suggest_fefo_positions(socket.assigns.product.id, amount,
             location_id: socket.assigns.location_id,
             box_id: box_id
           ) do
        {:ok, picks} ->
          with_box_codes(picks, socket.assigns.box_options)

        {:insufficient_stock, picks, _missing} ->
          with_box_codes(picks, socket.assigns.box_options)
      end
    else
      _invalid -> nil
    end
  end

  defp with_box_codes(picks, box_options) do
    Enum.map(picks, &Map.put(&1, :box_code, box_code_for(box_options, &1.box_id)))
  end

  defp box_code_for(box_options, box_id) do
    case Enum.find(box_options, &(&1.box_id == box_id)) do
      nil -> nil
      box -> box.box_code
    end
  end

  defp location_name(locations, id) do
    case Enum.find(locations, &(&1.id == id)) do
      nil -> nil
      location -> location.name
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Write off")}
        <:subtitle>
          {gettext("Goods leaving without an invoice or a kit. FEFO picks the lot.")}
        </:subtitle>
      </.header>

      <form
        id="search-form"
        phx-change="search"
        phx-submit="scan"
        class="field-row mt-4"
      >
        <label class="fieldset">
          <span class="label">{gettext("From")}</span>
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
        <label class="fieldset grow">
          <span class="label">{gettext("Product")}</span>
          <input
            type="search"
            name="query"
            value={@query}
            placeholder={gettext("Name, supplier code or GTIN")}
            class="input input-bordered w-full"
            phx-debounce="300"
          />
        </label>
      </form>

      <p :if={@query != "" and @products == []} class="mt-4 opacity-70">
        {gettext("No product matches that.")}
      </p>

      <ul :if={@products != []} class="menu bg-base-100 border border-base-300 rounded-box mt-4">
        <li :for={result <- @products}>
          <button phx-click="pick" phx-value-product={result.product.id} class="justify-between">
            <span>
              {result.product.name}
              <span :if={result.matched != :name} class="badge badge-sm">
                {match_label(result.matched)}
              </span>
            </span>
            <span class="tabular-nums text-sm text-base-content/80">
              {quantity(available(result.product, @location_id))}
            </span>
          </button>
        </li>
      </ul>

      <!-- The basket. Nothing here has been written, which is the whole point:
           a line added by mistake is removed rather than corrected by an
           adjustment filed forever. And six things taken at one counter are one
           movement, not six. -->
      <form
        :if={@basket != []}
        id="basket-form"
        phx-submit="issue"
        phx-change="destination"
        class="mt-6"
      >
        <.panel title={gettext("Leaving together")} flush>
          <.data_table rows={Enum.with_index(@basket)} row_id={fn {_line, i} -> "line-#{i}" end}>
            <:col :let={{line, _i}} label={gettext("Product")} emphasis={:identity}>
              {line.product}
            </:col>
            <:col :let={{line, _i}} label={gettext("Box")} emphasis={:muted}>
              {line.box_code || gettext("FEFO — automatic")}
            </:col>
            <:col :let={{line, _i}} label={gettext("Quantity")} align={:right} emphasis={:primary}>
              {quantity(line.quantity)}
            </:col>
            <:col
              :let={{line, index}}
              label={gettext("Actions")}
              hide_label_on_card={true}
              field={:inline}
              group
            >
              <div class="flex justify-end">
                <!-- An icon, because this repeats on every line and the word
                     took a column's worth of width from the numbers. Named for
                     the screen reader and on hover, both saying *which* line —
                     an icon-only destructive action with a bare "Remove" is a
                     guess, and this list is how much leaves the shelf. -->
                <button
                  type="button"
                  phx-click="drop"
                  phx-value-index={index}
                  class="btn btn-sm btn-ghost btn-square"
                  aria-label={gettext("Remove %{product}", product: line.product)}
                  title={gettext("Remove %{product}", product: line.product)}
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </:col>
          </.data_table>
        </.panel>

        <div class="field-row mt-4">
          <label class="fieldset">
            <span class="label">{gettext("Where to")}</span>
            <select name="destination" class="select select-bordered">
              <option value="">{gettext("not stated")}</option>
              <option
                :for={destination <- Transaction.destinations()}
                value={destination}
                selected={destination == @destination}
              >
                {destination_label(destination)}
              </option>
            </select>
          </label>

          <label :if={@destination == "donation"} class="fieldset">
            <span class="label">{gettext("Recipient")}</span>
            <input
              type="text"
              name="recipient_name"
              placeholder={gettext("hospital or institution")}
              class="input input-bordered w-64"
              aria-label={gettext("Name of the hospital or institution")}
            />
          </label>

          <label :if={@destination == "donation"} class="fieldset">
            <span class="label">{gettext("Recipient CNPJ")}</span>
            <input
              type="text"
              name="recipient_tax_id"
              inputmode="numeric"
              placeholder={gettext("optional")}
              class="input input-bordered w-52"
              aria-label={gettext("CNPJ of the hospital or institution")}
            />
          </label>

          <label class="fieldset grow">
            <span class="label">{gettext("Note")}</span>
            <input
              type="text"
              name="notes"
              placeholder={gettext("anything the destination does not already say")}
              class="input input-bordered w-full"
            />
          </label>
        </div>

        <div class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-4">
          <.commit_action
            id="confirm-issue"
            form="basket-form"
            label={gettext("Write off")}
            title={gettext("Take these goods out of stock?")}
            emphasis={:loud}
          >
            <:consequence>
              <p>
                {gettext("%{count} item(s) leave %{location}.",
                  count: length(@basket),
                  location: location_name(@locations, @location_id) || "—"
                )}
              </p>
              <p class="text-sm">
                {gettext("FEFO picks the lots: whatever expires first goes first.")}
              </p>
            </:consequence>
          </.commit_action>
        </div>
      </form>

      <form
        :if={@product}
        id="issue-form"
        phx-submit="add"
        phx-change="preview"
        class="panel"
      >
        <div class="panel-body space-y-3">
          <h2 class="font-semibold">{@product.name}</h2>
          <p class="text-sm opacity-70">
            {gettext("%{quantity} available here",
              quantity: quantity(available(@product, @location_id))
            )}
          </p>

          <!-- FEFO already reaches for the box that expires first on its own —
               this is a way to say "somewhere else instead", not a step
               anyone has to take. Left blank, nothing here changes. -->
          <label :if={box_choice?(@box_options)} class="fieldset">
            <span class="label">{gettext("Take it from")}</span>
            <select name="box_id" class="select select-bordered w-full">
              <option value="">
                {gettext("Let the system choose (recommended: %{box})",
                  box: short_box_label(recommended_box(@box_options))
                )}
              </option>
              <option :for={box <- @box_options} value={box.box_id}>
                {box_label(box)}
              </option>
            </select>
          </label>

          <div class="field-row">
            <label class="fieldset">
              <span class="label">{gettext("Quantity")}</span>
              <!-- The value comes from the server, and it has to.
                   `phx-change` repaints this form on every keystroke, and an
                   input rendered without a value is repainted *empty*: the
                   operator typed "30", the FEFO preview appeared, and the field
                   they were still typing into went blank under them. Reported as
                   a bug, and read as one — it looks exactly like the app
                   throwing the number away.

                   The conference screen learned this first and calls it a draft;
                   here one field is enough. Empty string rather than nil, so
                   the field always carries a `value` — nil renders no attribute
                   at all, and a reader cannot tell that from an oversight. -->
              <input
                type="text"
                name="quantity"
                value={@quantity}
                inputmode="decimal"
                data-numeric
                phx-debounce="300"
                class="input input-bordered w-28"
                aria-label={gettext("Quantity to issue")}
                phx-mounted={JS.focus()}
              />
            </label>
            <!-- Only for the stock that is sold. It sits beside the quantity
                 because a price belongs to the line, not to the write-off: two
                 shirts at 18,50 and a mug at 12,90 leave on one movement, and a
                 single price at the bottom could not describe it.

                 `value` from the server for the same reason the quantity has
                 one — `phx-change` repaints this form on every keystroke, and a
                 field rendered without a value comes back empty under the
                 person typing into it. -->
            <label :if={sellable?(@product)} class="fieldset">
              <span class="label">{gettext("Sale price (unit)")}</span>
              <input
                type="text"
                name="sale_unit_price"
                value={@sale_unit_price}
                inputmode="decimal"
                data-numeric
                phx-debounce="300"
                class="input input-bordered w-28 text-right"
                aria-label={gettext("Unit sale price")}
              />
            </label>
            <.button variant="primary">{gettext("Add to the write-off")}</.button>
            <button type="button" phx-click="clear_product" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
          </div>

          <!-- Below the field, never above it. It appears while somebody is
               typing, and anything that appears above the input pushes the
               input — and the button beside it — down mid-keystroke. Same rule
               the conference rows are built on: what shows up on its own does
               not get to move what the thumb is already aimed at. -->
          <div :if={@picks} class="text-sm">
            <p class="font-medium">{gettext("Will come out of:")}</p>
            <ul class="list-disc list-inside opacity-80">
              <li :for={pick <- @picks}>
                {gettext("lot %{lot}", lot: pick.lot_number || gettext("unknown"))}
                <span :if={pick.expires_on}>· {date(pick.expires_on)}</span>
                <span :if={pick.box_code}> · {pick.box_code}</span> — {quantity(pick.take)}
              </li>
            </ul>
          </div>
        </div>
      </form>

      <!-- What is on the shelf, for the person standing in front of it. The
           search is for whoever knows the catalog name; this is for whoever
           knows the thing. Only what is actually here: offering a product with
           no stock is a write-off that fails at the last step.

           Hidden while a search is open, so the screen never shows two
           competing lists of products at once. -->
      <.panel
        :if={@query == "" and is_nil(@product)}
        title={gettext("Here right now")}
        note={location_name(@locations, @location_id)}
        flush
      >
        <.data_table rows={@here} row_id={&"here-#{&1.product_id}"}>
          <:empty>
            <.empty
              title={gettext("Nothing is in stock at this location.")}
              note={gettext("Pick another location, or bring goods in first.")}
            />
          </:empty>

          <:col :let={row} label={gettext("Product")} emphasis={:identity}>
            {row.product}
            <.status :if={row.controlled} kind={:controlled} />
            <!-- Where to reach for it. The list said what was at the location
                 and not where it was, which on a shelf of forty boxes is most
                 of the work. -->
            <p :if={row.boxes != []} class="text-xs opacity-60">
              {gettext("in %{boxes}", boxes: Enum.join(row.boxes, ", "))}
            </p>
            <p :if={row.boxes == []} class="text-xs opacity-60">{gettext("loose")}</p>
          </:col>

          <:col :let={row} label={gettext("Here")} align={:right} emphasis={:primary}>
            {quantity(row.quantity)}
            <span class="text-xs font-normal opacity-60">{row.stock_unit}</span>
          </:col>

          <:col :let={row} label={gettext("Actions")} hide_label_on_card={true} field={:inline} group>
            <div class="flex justify-end">
              <!-- "Separar", not "Adicionar". This screen takes goods *out* of
                   stock, and a row whose action reads "add" says the opposite of
                   what the screen does — reported as reading like an antithesis.
                   Picking is the warehouse's own word for gathering what is
                   about to leave, and it is what this click actually starts. -->
              <button
                phx-click="pick"
                phx-value-product={row.product_id}
                class="btn btn-sm"
              >
                {gettext("Pick")}
              </button>
            </div>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp match_label(:gtin), do: gettext("GTIN")
  defp match_label(:supplier_code), do: gettext("supplier code")
  defp match_label(:synonym), do: gettext("synonym")

  defp available(product, location_id) do
    Inventory.balance(product_id: product.id, location_id: location_id)
  end

  @impl true
  def handle_event("search", %{"query" => query} = params, socket) do
    location_id = String.to_integer(params["location_id"] || "#{socket.assigns.location_id}")

    products = Catalog.search_products(query, limit: 8, segment: socket.assigns.segment)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:location_id, location_id)
     |> assign(:products, products)
     |> load_here()}
  end

  def handle_event("scan", %{"query" => query}, socket) do
    case Catalog.find_by_code(query, segment: socket.assigns.segment) do
      nil ->
        {:noreply,
         assign(
           socket,
           :products,
           Catalog.search_products(query, limit: 8, segment: socket.assigns.segment)
         )}

      product ->
        {:noreply,
         socket
         |> assign(:products, [])
         |> pick_product(product)
         |> put_flash(:info, gettext("%{product} found by code.", product: product.name))}
    end
  end

  def handle_event("pick", %{"product" => product_id}, socket) do
    product = Catalog.get_product!(String.to_integer(product_id))

    if socket.assigns.segment && product.segment != socket.assigns.segment do
      {:noreply, put_flash(socket, :error, gettext("That product is not in this stock."))}
    else
      {:noreply,
       socket
       |> assign(:products, [])
       |> pick_product(product)}
    end
  end

  # Only to reveal the CNPJ field when the destination is a donation; the rest of
  # the form keeps its own values in the DOM.
  def handle_event("destination", params, socket) do
    {:noreply, assign(socket, :destination, blank_to_nil(params["destination"]))}
  end

  # Recomputes the FEFO preview whenever the quantity or the chosen box
  # changes — this is what finally answers "will come out of", rather than
  # asking the operator to trust a pick they cannot see.
  def handle_event("preview", params, socket) do
    {:noreply,
     socket
     |> assign(:quantity, params["quantity"])
     |> assign(:sale_unit_price, params["sale_unit_price"] || "")
     |> assign(:picks, compute_picks(socket, params))}
  end

  # Adds to the basket. Nothing is written until the whole thing is confirmed,
  # which is what makes a mistyped line removable — once posted it could only be
  # undone by a correcting adjustment filed forever.
  def handle_event("add", %{"quantity" => quantity} = params, socket) do
    product = socket.assigns.product

    case to_decimal(quantity) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Type a quantity greater than zero."))}

      amount ->
        if Decimal.compare(amount, 0) != :gt do
          {:noreply, put_flash(socket, :error, gettext("Type a quantity greater than zero."))}
        else
          box_id = to_id(params["box_id"])
          box_code = box_code_for(socket.assigns.box_options, box_id)

          {:noreply,
           socket
           |> assign(
             :basket,
             socket.assigns.basket ++
               [
                 basket_line(product, amount, box_id, box_code,
                   sale_unit_price: to_decimal(params["sale_unit_price"])
                 )
               ]
           )
           |> assign(:product, nil)
           |> assign(:box_options, [])
           |> assign(:picks, nil)
           |> assign(:quantity, "")
           |> assign(:sale_unit_price, "")
           |> assign(:query, "")
           |> assign(:products, [])}
        end
    end
  end

  def handle_event("clear_product", _params, socket) do
    {:noreply,
     socket
     |> assign(:product, nil)
     |> assign(:box_options, [])
     |> assign(:picks, nil)
     |> assign(:quantity, "")
     |> assign(:sale_unit_price, "")
     |> assign(:query, "")
     |> assign(:products, [])}
  end

  def handle_event("drop", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply, assign(socket, :basket, List.delete_at(socket.assigns.basket, index))}
  end

  def handle_event("issue", params, socket) do
    case Outbound.issue_many(socket.assigns.basket, %{
           location_id: socket.assigns.location_id,
           destination: blank_to_nil(params["destination"]),
           recipient_name: blank_to_nil(params["recipient_name"]),
           recipient_tax_id: blank_to_nil(params["recipient_tax_id"]),
           notes: params["notes"],
           user_id: socket.assigns.current_scope.user.id
         }) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{count} item(s) issued.", count: length(socket.assigns.basket))
         )
         |> assign(:basket, [])
         |> assign(:product, nil)
         |> assign(:box_options, [])
         |> assign(:picks, nil)
         |> assign(:quantity, "")
         |> assign(:sale_unit_price, "")
         |> assign(:destination, nil)
         |> assign(:query, "")
         # The shelf just changed, and this screen is now showing it.
         |> load_here()}

      {:error, :nothing_to_issue} ->
        {:noreply, put_flash(socket, :error, gettext("Add something to the list first."))}

      {:error, :missing_sale_price} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A sale needs the sale price on every line. Remove the line and add it again.")
         )}

      {:error, {:insufficient_stock, %{missing: missing}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Not enough here: %{missing} missing.", missing: quantity(missing))
         )}

      {:error, :invalid_quantity} ->
        {:noreply, put_flash(socket, :error, gettext("Type a quantity greater than zero."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The issue could not be recorded."))}
    end
  end
end
