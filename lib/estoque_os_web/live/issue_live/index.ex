defmodule EstoqueOSWeb.IssueLive.Index do
  @moduledoc """
  Manual issue: someone came and took things. Search is by name; FEFO picks the lot.
  """

  use EstoqueOSWeb, :live_view

  import EstoqueOS.Coercion, only: [to_decimal: 1, to_id: 1, blank_to_nil: 1]

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.{Catalog, Inventory, Outbound, Reports}
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Inventory.Transaction

  import EstoqueOSWeb.Movement, only: [destination_label: 1]

  # Events a viewer may send; everything else is refused. The basket lives in
  # the socket until `issue` posts it.
  def viewer_events, do: ~w(search scan pick destination preview add drop clear_product)

  @impl true
  def mount(_params, _session, socket) do
    locations = Locations.list_locations()
    segment = Scope.default_segment(socket.assigns.current_scope)
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
     |> assign(:lot_options, [])
     |> assign(:picks, nil)
     |> assign(:quantity, "")
     |> assign(:sale_unit_price, "")
     |> assign(:destination, nil)
     |> assign(:recipient_name, "")
     |> assign(:recipient_tax_id, "")
     |> assign(:notes, "")
     |> assign(:basket, [])
     |> load_here()}
  end

  # From a product page: opens with the product picked. An unresolvable id just
  # opens the screen as usual.
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

  # From the end of a mission: basket pre-filled as a donation at the mission
  # site. Lines are rebuilt from the ledger, not trusted from the address, so a
  # stale link fills a shorter basket instead of posting a vanished quantity.
  def handle_params(%{"donate" => lots, "location" => location_id} = params, _uri, socket) do
    socket = assign_segment(socket, params)

    with {location_id, ""} <- Integer.parse(location_id),
         [_ | _] = wanted <- parse_ids(lots),
         [_ | _] = lines <- donation_lines(location_id, wanted) do
      {:noreply,
       socket
       |> assign(:location_id, location_id)
       |> assign(:destination, "donation")
       |> assign(:basket, lines)
       |> load_here()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("That stock is no longer here."))}
    end
  end

  def handle_params(params, _uri, socket), do: {:noreply, assign_segment(socket, params)}

  defp parse_ids(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case Integer.parse(part) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
  end

  # Whole positions: the lot is not worth flying home. Partial donations go by hand.
  defp donation_lines(location_id, wanted) do
    [limit: nil, location_id: location_id]
    |> Reports.expiring_soon()
    |> Enum.filter(&(&1.lot_id in wanted))
    |> Enum.map(fn row ->
      %{
        product_id: row.product_id,
        product: row.product,
        quantity: row.quantity,
        box_id: row.box_id,
        box_code: row.box,
        lot_id: row.lot_id,
        lot_number: row.lot_number,
        sale_unit_price: nil
      }
    end)
  end

  # The role wins over the address. Every product listing passes the segment
  # down, so narrowing is a query `where`, not a template that renders fewer rows.
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

  # `box_code` is display only; `box_id` pins the pick when set.
  defp basket_line(product, quantity, box_id, box_code, opts) do
    %{
      product_id: product.id,
      product: product.name,
      quantity: quantity,
      box_id: box_id,
      box_code: box_code,
      lot_id: opts[:lot_id],
      lot_number: opts[:lot_number],
      sale_unit_price: opts[:sale_unit_price]
    }
  end

  # A price belongs to a sale, not to the product's segment.
  defp sellable?(destination), do: destination == "sale"

  # Marketing material is only sold or given away.
  defp destinations_for("marketing"), do: ~w(sale donation)
  defp destinations_for(_segment), do: Transaction.destinations()

  defp box_choice?(box_options), do: length(box_options) > 1

  # The box FEFO would reach for; undated stock sorts last. Keyed on the ISO 8601
  # string because `Date` structs compare field by field (day first), not by
  # calendar.
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

  # Short on purpose: a longer default option is cut off by a native `<select>`.
  defp short_box_label(%{box_code: nil}), do: gettext("loose")
  defp short_box_label(%{box_code: code}), do: code

  defp expiry_label(nil), do: gettext("unknown")
  defp expiry_label(%Date{} = expires_on), do: date(expires_on)

  defp pick_product(socket, product) do
    socket
    |> assign(:product, product)
    |> assign(:box_options, Inventory.box_quantities(product.id, socket.assigns.location_id))
    |> assign(:lot_options, lot_options(product, socket.assigns.location_id))
    |> assign(:picks, nil)
    |> assign(:quantity, "")
    |> assign(:sale_unit_price, "")
  end

  # Lets the operator override FEFO, e.g. for shirts, which have no expiry to sort by.
  defp lot_options(product, location_id) do
    product.id
    |> Inventory.lot_balances(location_id: location_id)
    |> Enum.reject(&(Decimal.compare(&1.quantity, 0) != :gt))
  end

  defp lot_choice?(lot_options), do: length(lot_options) > 1

  defp lot_label(%{lot_number: nil, quantity: quantity, expires_on: nil}) do
    gettext("lot not stated — %{qty}", qty: quantity(quantity))
  end

  defp lot_label(%{lot_number: number, quantity: quantity, expires_on: nil}) do
    gettext("lot %{lot} — %{qty}", lot: number, qty: quantity(quantity))
  end

  defp lot_label(%{lot_number: number, quantity: quantity, expires_on: expires_on}) do
    gettext("lot %{lot} — %{qty} — expires %{expiry}",
      lot: number || gettext("not stated"),
      qty: quantity(quantity),
      expiry: date(expires_on)
    )
  end

  defp lot_number_for(lot_options, lot_id) do
    case Enum.find(lot_options, &(&1.lot_id == lot_id)) do
      nil -> nil
      lot -> lot.lot_number
    end
  end

  defp compute_picks(socket, params) do
    with %Decimal{} = amount <- to_decimal(params["quantity"]),
         :gt <- Decimal.compare(amount, 0) do
      box_id = to_id(params["box_id"])
      lot_id = to_id(params["lot_id"])

      case Inventory.suggest_fefo_positions(socket.assigns.product.id, amount,
             location_id: socket.assigns.location_id,
             box_id: box_id,
             lot_id: lot_id
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
          {gettext(
            "Goods leaving without an invoice or a kit. FEFO picks the lot unless you say otherwise."
          )}
        </:subtitle>
      </.header>

      <%!-- Decided before anything is picked: the price field depends on the destination. --%>
      <form id="destination-form" phx-change="destination" class="panel mt-4">
        <div class="panel-body field-row">
          <label class="fieldset">
            <span class="label">{gettext("Where to")}</span>
            <%!-- Required, no "not stated" fallback: a blank destination cannot be filled in afterwards. --%>
            <select name="destination" class="select select-bordered" required>
              <option value="" disabled selected={is_nil(@destination)}>
                {gettext("choose one")}
              </option>
              <option
                :for={destination <- destinations_for(@segment)}
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
              value={@recipient_name}
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
              value={@recipient_tax_id}
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
              value={@notes}
              placeholder={gettext("anything the destination does not already say")}
              class="input input-bordered w-full"
            />
          </label>
        </div>
      </form>

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

      <%!-- Basket: nothing is written yet, so a mistaken line is removed, not corrected by an adjustment; items taken together are one movement. --%>
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
            <:col :let={{line, _i}} label={gettext("Lot")} emphasis={:muted}>
              {line.lot_number || gettext("FEFO — automatic")}
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
                <%!-- Icon-only, but named with the product for screen readers and hover. --%>
                <button
                  type="button"
                  phx-click="drop"
                  phx-value-index={index}
                  class="btn btn-ghost btn-square btn-sm"
                  aria-label={gettext("Remove %{product}", product: line.product)}
                  title={gettext("Remove %{product}", product: line.product)}
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </:col>
          </.data_table>
        </.panel>

        <div class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-4">
          <.commit_action
            id="confirm-issue"
            form="basket-form"
            label={gettext("Write off")}
            title={gettext("Take these goods out of stock?")}
            emphasis={:loud}
            disabled={is_nil(@destination)}
            reason={if is_nil(@destination), do: gettext("Say where the goods are going first.")}
          >
            <:consequence>
              <p>
                {gettext("%{count} item(s) leave %{location}.",
                  count: length(@basket),
                  location: location_name(@locations, @location_id) || "—"
                )}
              </p>
              <p class="text-sm">
                {gettext("Lines with no lot chosen go FEFO: whatever expires first goes first.")}
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

          <label :if={lot_choice?(@lot_options)} class="fieldset">
            <span class="label">{gettext("Which lot")}</span>
            <select name="lot_id" class="select select-bordered w-full">
              <option value="">{gettext("Let the system choose (first to expire)")}</option>
              <option :for={lot <- @lot_options} value={lot.lot_id}>{lot_label(lot)}</option>
            </select>
          </label>

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
              <%!-- value must come from the server: `phx-change` repaints this form on every keystroke and a value-less input is emptied under the typist. Empty string, not nil, so the attribute is always rendered. --%>
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
            <%!-- Price is per line (items sold at different prices share one movement). Server-rendered value, as for the quantity. --%>
            <label :if={sellable?(@destination)} class="fieldset">
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
            <.button variant="ghost" type="button" phx-click="clear_product">
              {gettext("Cancel")}
            </.button>
          </div>

          <%!-- Below the field, never above: it appears mid-keystroke and would push the input down. --%>
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

      <%!-- Only what is actually here, since an out-of-stock write-off fails at the last step. Hidden while a search is open. --%>
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
              <%!-- "Pick", not "Add": this screen takes goods out of stock. --%>
              <.button
                phx-click="pick"
                phx-value-product={row.product_id}
                class="btn-sm"
              >
                {gettext("Pick")}
              </.button>
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
  defp match_label(:alias), do: gettext("other name")

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

  # The whole "where to" block: reveals the CNPJ field for a donation and keeps its values.
  def handle_event("destination", params, socket) do
    {:noreply,
     socket
     |> assign(:destination, blank_to_nil(params["destination"]))
     |> assign(:recipient_name, params["recipient_name"] || "")
     |> assign(:recipient_tax_id, params["recipient_tax_id"] || "")
     |> assign(:notes, params["notes"] || "")}
  end

  # Recomputes the FEFO preview when the quantity or chosen box changes.
  def handle_event("preview", params, socket) do
    {:noreply,
     socket
     |> assign(:quantity, params["quantity"])
     |> assign(:sale_unit_price, params["sale_unit_price"] || "")
     |> assign(:picks, compute_picks(socket, params))}
  end

  # Adds to the basket; nothing is written until confirmed.
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
          lot_id = to_id(params["lot_id"])

          {:noreply,
           socket
           |> assign(
             :basket,
             socket.assigns.basket ++
               [
                 basket_line(product, amount, box_id, box_code,
                   lot_id: lot_id,
                   lot_number: lot_number_for(socket.assigns.lot_options, lot_id),
                   sale_unit_price: to_decimal(params["sale_unit_price"])
                 )
               ]
           )
           |> assign(:product, nil)
           |> assign(:box_options, [])
           |> assign(:lot_options, [])
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

  def handle_event("issue", _params, socket) do
    case Outbound.issue_many(socket.assigns.basket, %{
           location_id: socket.assigns.location_id,
           destination: socket.assigns.destination,
           recipient_name: blank_to_nil(socket.assigns.recipient_name),
           recipient_tax_id: blank_to_nil(socket.assigns.recipient_tax_id),
           notes: blank_to_nil(socket.assigns.notes),
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
         |> assign(:recipient_name, "")
         |> assign(:recipient_tax_id, "")
         |> assign(:notes, "")
         |> assign(:query, "")
         |> load_here()}

      {:error, :nothing_to_issue} ->
        {:noreply, put_flash(socket, :error, gettext("Add something to the list first."))}

      # Named, or the catch-all hides which field blocks the operator.
      {:error, :missing_destination} ->
        {:noreply, put_flash(socket, :error, gettext("Say where the goods are going first."))}

      {:error, :missing_location} ->
        {:noreply, put_flash(socket, :error, gettext("Say which stock they leave first."))}

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
