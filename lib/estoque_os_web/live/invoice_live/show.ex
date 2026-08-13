defmodule EstoqueOSWeb.InvoiceLive.Show do
  @moduledoc """
  Step 2 of the import: confirm what each line is, how many units come in the
  supplier's packaging, and post the whole thing into the ledger.

  The unit price — the number that costs the coordinator a week of manual work
  per mission — is shown live as the conversion factor is typed.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Searching the catalog resolves nothing on its own, and neither does choosing
  what a line will be: `pick`, `choose_new` and `unpick` move a selection around
  in this session and touch no row. Only `resolve` writes it down. Posting the
  invoice and opening a receipt write too.
  """
  def viewer_events,
    do:
      ~w(search edit cancel_edit pick choose_new unpick preview_factor open_matches close_matches)

  import EstoqueOS.Coercion, only: [to_decimal: 1]

  alias EstoqueOS.{Catalog, Invoices, Receiving}

  alias EstoqueOS.Inventory.Locations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    invoice = Invoices.get_invoice!(id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Invoice %{number}", number: invoice.number))
     |> assign(:locations, Locations.list_locations())
     |> assign(:location_id, default_location_id())
     |> assign(:candidates, %{})
     # What the operator typed into each line's one field, what they picked out
     # of the list, and the lines where they chose to create instead. Together
     # these are the state of the picker, per line, held here because the field
     # and the list are the same control and have to agree.
     |> assign(:queries, %{})
     |> assign(:chosen, %{})
     |> assign(:creating, MapSet.new())
     # What was typed into the conversion factor, per line, so the unit price
     # can answer as it is typed instead of only after the line is confirmed.
     |> assign(:factors, %{})
     # Lines whose suggestion list is open. The list belongs to the field, so it
     # appears when the field is being used and goes away when it is not.
     |> assign(:browsing, MapSet.new())
     # Lines a resolved item has been reopened on. A confirmed line collapses
     # to its summary; this is the way back in.
     |> assign(:editing, MapSet.new())
     |> assign(:posted, nil)
     |> assign_invoice(invoice)
     |> assign_receipts(invoice)}
  end

  defp default_location_id do
    case Locations.default_location() do
      nil -> nil
      location -> location.id
    end
  end

  defp assign_receipts(socket, invoice) do
    receipts = if invoice.status == "posted", do: Receiving.list_receipts(invoice), else: []

    socket
    |> assign(:receipts, receipts)
    |> assign(:open_receipt, Enum.find(receipts, &(&1.status == "draft")))
  end

  defp assign_invoice(socket, invoice) do
    socket
    |> assign(:invoice, invoice)
    |> assign(:unresolved, Invoices.unresolved_items(invoice))
    |> assign(:suspicious, Invoices.suspicious_items(invoice))
    |> assign(:candidates, candidates_for(invoice, socket.assigns[:candidates] || %{}))
  end

  # Ranked catalog suggestions per unresolved line, computed once and kept in
  # assigns so typing a search only recomputes the row being searched.
  defp candidates_for(invoice, existing) do
    Enum.reduce(invoice.items, existing, fn item, acc ->
      cond do
        item.product_id -> Map.delete(acc, item.id)
        Map.has_key?(acc, item.id) -> acc
        true -> Map.put(acc, item.id, suggestions(item))
      end
    end)
  end

  defp suggestions(item) do
    item.description
    |> Catalog.suggest_products(item.ncm)
    |> Enum.map(& &1.product)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="space-y-6">
        <.header back_to={~p"/invoices"} back_label={gettext("Invoices")}>
          {gettext("Invoice %{number}", number: @invoice.number)}
          <:subtitle>
            {@invoice.supplier.legal_name} · {gettext("issued on %{date}",
              date: date(@invoice.issued_on)
            )} · {money(@invoice.total)}
          </:subtitle>
          <:actions>
            <.status
              :if={@invoice.status == "posted"}
              kind={:complete}
              detail={gettext("Posted to stock")}
            />
            <.status
              :if={@invoice.status != "posted"}
              kind={:pending}
              detail={gettext("%{count} item(s) pending", count: length(@unresolved))}
            />
          </:actions>
        </.header>

        <section
          :if={@posted}
          class="rounded-box border border-success/40 bg-success/10 p-4"
        >
          <h2 class="text-lg font-semibold">
            {gettext("Invoice %{number} is in stock.", number: @invoice.number)}
          </h2>
          <p class="mt-1">
            {gettext("%{items} item(s) · %{units} unit(s) · %{value} · %{location}",
              items: @posted.items,
              units: quantity(@posted.units),
              value: money(@posted.value),
              location: @posted.location
            )}
          </p>
          <p class="mt-1 text-sm">
            {gettext(
              "Unit prices are on record; the next invoice from %{supplier} matches on its own.",
              supplier: @invoice.supplier.legal_name
            )}
          </p>
          <div class="mt-3 flex flex-wrap gap-3">
            <.link navigate={~p"/stock"} class="btn btn-sm">{gettext("See stock")}</.link>
            <button
              :if={is_nil(@open_receipt)}
              phx-click="start_receipt"
              class="btn btn-sm btn-outline"
            >
              {gettext("Start conference")}
            </button>
          </div>
        </section>

        <div :if={@invoice.events != []} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-5" />
          <span>
            {gettext("This invoice has %{count} correction letter(s) attached.",
              count: length(@invoice.events)
            )}
          </span>
        </div>

        <div :if={@suspicious != []} class="alert alert-warning flex-col items-start gap-2">
          <p class="font-semibold">
            {gettext("Check these unit prices before posting")}
          </p>
          <ul class="list-disc list-inside text-sm">
            <li :for={warning <- @suspicious}>
              {gettext(
                "%{description}: %{now} per unit against %{previous} last time (%{factor}x)",
                description: warning.item.description,
                now: money(warning.item.unit_cost),
                previous: money(warning.previous),
                factor: Decimal.round(warning.factor, 1)
              )}
            </li>
          </ul>
        </div>

        <!-- One line, one card. This was a table, and the columns were sized
             from their content: confirming one row changed the width of all of
             them, and the product name — long, and longer than the supplier's
             own wording — landed in a badge that cannot wrap. The row has to
             settle when it is confirmed, and a card can do that where a shared
             column cannot. -->
        <!-- Once it is posted there are no decisions left on this screen, and a
             card per line is a screen you scroll to read four columns. What it
             becomes is what it now is: a record, read across. -->
        <.panel :if={@invoice.status == "posted"} title={gettext("What was posted")} flush>
          <.data_table rows={@invoice.items} row_id={&"item-#{&1.id}"}>
            <:col :let={item} label={gettext("Product")} emphasis={:identity}>
              {(item.product && item.product.name) || item.description}
              <!-- The supplier's own wording stays reachable, small: it is what
                   is printed on the box somebody is holding, and it is how a
                   line gets recognised when the catalog name does not match
                   what is written on the carton. -->
              <p :if={item.product} class="text-xs opacity-60">{item.description}</p>
            </:col>

            <:col :let={item} label={gettext("Lot")}>
              {item.lot_number || "—"}
              <p :if={item.expires_on} class="text-xs opacity-60">{date(item.expires_on)}</p>
            </:col>

            <:col :let={item} label={gettext("Quantity")} align={:right}>
              {quantity(item.commercial_quantity)} {item.commercial_unit}
              <p class="text-xs opacity-60">
                {gettext("1 %{unit} = %{factor}",
                  unit: item.commercial_unit,
                  factor: quantity(item.conversion_factor)
                )}
              </p>
            </:col>

            <:col :let={item} label={gettext("Unit price")} align={:right} emphasis={:primary}>
              {unit_price(item.unit_cost)}
            </:col>
          </.data_table>
        </.panel>

        <section :if={@invoice.status != "posted"} class="space-y-3">
          <article
            :for={item <- @invoice.items}
            id={"item-#{item.id}"}
            class={["panel", resolved?(item, @editing) && "border-success/40"]}
          >
            <div class="panel-body space-y-2">
              <!-- What the supplier wrote, in full and never truncated: it is
                   the only description of the goods that exists until somebody
                   matches it, and it carries the lot and dates glued on. -->
              <header class="flex flex-wrap items-start justify-between gap-x-6 gap-y-1">
                <div class="min-w-0">
                  <p class="font-medium">{item.description}</p>
                  <p class="text-xs opacity-60">
                    {gettext("code %{code}", code: item.supplier_product_code || "—")}
                    <span :if={item.gtin}>· GTIN {item.gtin}</span>
                    · {quantity(item.commercial_quantity)} {item.commercial_unit} × {money(
                      item.commercial_unit_value
                    )}
                  </p>
                </div>

                <.status
                  :if={resolved?(item, @editing)}
                  kind={:complete}
                  detail={gettext("confirmed")}
                />
                <.status
                  :if={item.needs_review and not resolved?(item, @editing)}
                  kind={:needs_review}
                />
              </header>

              <!-- CONFIRMED: everything the line decided, on one line, with the
                   unit price loud. This is the number the whole system exists to
                   produce. -->
              <div
                :if={resolved?(item, @editing)}
                class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2 border-t border-base-200 pt-2"
              >
                <div class="min-w-0">
                  <p class="font-medium">{item.product.name}</p>
                  <p class="text-xs opacity-70">
                    {gettext("1 %{unit} = %{factor}",
                      unit: item.commercial_unit,
                      factor: quantity(item.conversion_factor)
                    )} · {gettext("lot %{lot}", lot: item.lot_number || gettext("not informed"))}
                    <span :if={item.expires_on}>
                      · {gettext("expires %{date}", date: date(item.expires_on))}
                    </span>
                  </p>
                </div>

                <div class="flex items-baseline gap-4 shrink-0">
                  <p class="text-lg font-semibold tabular-nums">{unit_price(item.unit_cost)}</p>
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-item={item.id}
                    class="btn btn-ghost btn-xs"
                  >
                    {gettext("Change")}
                  </button>
                </div>
              </div>

              <!-- UNRESOLVED: the whole width, because this is where the work is. -->
              <div :if={not resolved?(item, @editing)} class="space-y-2 border-t border-base-200 pt-2">
                <!-- One field. It used to be two — a search box, and a separate
                     "Corresponde a" droplist that the results landed in — so
                     typing appeared to do nothing and the suggestions seemed to
                     come from opening an empty droplist. They were always one
                     question: what is this line?

                     The matches hang off the field rather than sitting under it
                     permanently: a list of ten that is always on screen makes a
                     card the operator has to scroll past on every line, when
                     nine lines in ten are decided by one glance and one click. -->
                <div
                  :if={is_nil(decided(assigns, item))}
                  id={"picker-#{item.id}"}
                  class="relative"
                  phx-click-away="close_matches"
                  phx-value-item={item.id}
                >
                  <form id={"search-#{item.id}"} phx-change="search" phx-value-item={item.id}>
                    <label class="fieldset">
                      <span class="label">{gettext("Product")}</span>
                      <input
                        type="search"
                        name="query"
                        value={@queries[item.id]}
                        class="input input-sm input-bordered w-full"
                        placeholder={gettext("Search the catalog")}
                        phx-debounce="300"
                        phx-focus="open_matches"
                        phx-value-item={item.id}
                        role="combobox"
                        aria-expanded={to_string(browsing?(assigns, item))}
                        aria-controls={"matches-#{item.id}"}
                      />
                    </label>
                  </form>

                  <!-- Suggestions before anything is typed, results after, and
                       creating always last. Offered above the matches it becomes
                       the fastest path, and the catalog fills with the same item
                       spelled three ways.

                       Absolute, so opening it does not shove the price and the
                       conversion factor down the page under the operator's
                       cursor. -->
                  <ul
                    :if={browsing?(assigns, item)}
                    id={"matches-#{item.id}"}
                    class="menu absolute z-20 top-full left-0 mt-1 w-full max-h-72 flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
                  >
                    <li :for={product <- @candidates[item.id] || []}>
                      <button
                        type="button"
                        phx-click="pick"
                        phx-value-item={item.id}
                        phx-value-product={product.id}
                      >
                        {product.name}
                      </button>
                    </li>
                    <li :if={@candidates[item.id] == []} class="menu-title text-xs">
                      {gettext("Nothing in the catalog matches that.")}
                    </li>
                    <li>
                      <button
                        type="button"
                        phx-click="choose_new"
                        phx-value-item={item.id}
                        class="text-primary"
                      >
                        <.icon name="hero-plus-circle" class="size-4" />
                        {gettext("Create a new product")}
                      </button>
                    </li>
                  </ul>
                </div>

                <form
                  id={"resolve-#{item.id}"}
                  phx-submit="resolve"
                  phx-change="preview_factor"
                  phx-value-item={item.id}
                  class="space-y-3"
                >
                  <!-- What the line was decided to be, once it has been decided.
                       Named out loud with a way back, because the decision is
                       otherwise invisible above a form full of numbers. -->
                  <div
                    :if={product = decided(assigns, item)}
                    class="flex flex-wrap items-center gap-2"
                  >
                    <p class="font-medium">
                      <span class="text-xs opacity-60 font-normal">{gettext("Matches")}:</span>
                      {product_label(product)}
                    </p>
                    <!-- Right after the name, not a separate text link off to the
                         side: the wrong product picked out of the catalog is a
                         mistake read at the name itself, and the way back should
                         sit where the eye already is. Icon-only per the button
                         vocabulary — the word survives as `title` and
                         `aria-label`. -->
                    <button
                      type="button"
                      phx-click="unpick"
                      phx-value-item={item.id}
                      class="btn btn-ghost btn-xs btn-square"
                      title={gettext("Change")}
                      aria-label={gettext("Change")}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>

                  <input
                    type="hidden"
                    name="product_id"
                    value={chosen_value(assigns, item)}
                  />

                  <!-- Only for a line about to become a new catalog product. It
                       used to be rendered on every unresolved line, which made
                       the card tall and asked a question most lines never face.

                       The operator still reads it before committing: a catalog
                       name outlives the invoice that introduced it, and the
                       supplier's wording arrives with the shipment's lot and
                       dates glued on, often truncated mid-word. -->
                  <label :if={creating?(assigns, item)} class="fieldset">
                    <span class="label">{gettext("Name of the new product")}</span>
                    <input
                      type="text"
                      name="new_product_name"
                      value={
                        @queries[item.id]
                        |> blank_to(Catalog.suggested_product_name(item.description))
                      }
                      class="input input-sm input-bordered w-full"
                      aria-label={gettext("Name for the new catalog product")}
                    />
                  </label>

                  <div class="field-row">
                    <label class="fieldset">
                      <span class="label">
                        {gettext("1 %{unit} =", unit: item.commercial_unit)}
                      </span>
                      <input
                        type="text"
                        name="conversion_factor"
                        value={@factors[item.id] || quantity(item.conversion_factor)}
                        inputmode="decimal"
                        data-numeric
                        class="input input-sm input-bordered w-24 text-right"
                        aria-label={gettext("Units per %{unit}", unit: item.commercial_unit)}
                      />
                    </label>

                    <label class="fieldset">
                      <span class="label">{gettext("Lot")}</span>
                      <input
                        type="text"
                        name="lot_number"
                        value={item.lot_number}
                        placeholder={gettext("if it has one")}
                        class="input input-sm input-bordered w-40"
                      />
                    </label>

                    <label class="fieldset">
                      <span class="label">{gettext("Expiry")}</span>
                      <input
                        type="date"
                        name="expires_on"
                        value={item.expires_on}
                        class="input input-sm input-bordered"
                        aria-label={gettext("Expiry date")}
                      />
                    </label>

                    <!-- Live, as the factor is typed: the unit price is the
                         answer this screen exists to give, and seeing it move is
                         how a wrong factor gets caught. -->
                    <div class="fieldset">
                      <span class="label">{gettext("Unit price")}</span>
                      <p class="text-lg font-semibold tabular-nums leading-tight">
                        {unit_price(preview_unit_cost(assigns, item))}
                      </p>
                      <span
                        :if={item.commercial_unit_value && preview_factor(assigns, item)}
                        class="text-xs opacity-70"
                      >
                        {gettext("%{value} ÷ %{factor}",
                          value: unit_price(item.commercial_unit_value),
                          factor: quantity(preview_factor(assigns, item))
                        )}
                      </span>
                    </div>

                    <!-- On the price's own line, pushed to the far corner. It
                         had a row of its own, which cost every card a line of
                         height for one button and put the whole width between
                         the number being confirmed and the button confirming
                         it. `ml-auto` keeps it in the corner while there is
                         room and lets it wrap on a phone like everything else
                         in this row. -->
                    <div class="fieldset ml-auto flex-row gap-2">
                      <button
                        :if={item.product_id}
                        type="button"
                        phx-click="cancel_edit"
                        phx-value-item={item.id}
                        class="btn btn-ghost"
                      >
                        {gettext("Cancel")}
                      </button>
                      <.button variant="primary" phx-disable-with={gettext("Saving...")}>
                        {gettext("Confirm")}
                      </.button>
                    </div>
                  </div>
                </form>
              </div>
            </div>
          </article>
        </section>

        <form
          :if={@invoice.status != "posted"}
          id="post-form"
          phx-submit="post"
          class="field-row border-t border-base-300 pt-4"
        >
          <label class="fieldset">
            <span class="label">{gettext("Receiving location")}</span>
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

          <.commit_action
            id="confirm-post"
            form="post-form"
            label={gettext("Post to stock")}
            title={gettext("Post this invoice to stock?")}
            disabled={@unresolved != []}
          >
            <:consequence>
              <p>
                {gettext("%{items} item(s) · %{units} unit(s) · %{value} enter stock.",
                  items: length(@invoice.items),
                  units: quantity(total_units(@invoice)),
                  value: money(@invoice.total)
                )}
              </p>
              <p :if={@suspicious != []} class="text-sm text-warning">
                {gettext("%{count} unit price(s) look wrong against this product's history.",
                  count: length(@suspicious)
                )}
              </p>
            </:consequence>
          </.commit_action>

          <p :if={@unresolved != []} class="text-sm opacity-70">
            {gettext("Confirm every item before posting.")}
          </p>
        </form>

        <section :if={@invoice.status == "posted"} class="border-t border-base-300 pt-4">
          <h2 class="font-semibold">{gettext("Receiving conference")}</h2>
          <p class="text-sm opacity-70">
            {gettext("Check what physically arrived against what the invoice promised.")}
          </p>

          <ul :if={@receipts != []} class="mt-2 text-sm">
            <li :for={receipt <- @receipts}>
              <.link navigate={~p"/receipts/#{receipt}"} class="link link-hover">
                {gettext("Round %{round}", round: receipt.round)}
              </.link>
              · {receipt_status_label(receipt.status)}
            </li>
          </ul>

          <button
            :if={is_nil(@open_receipt)}
            phx-click="start_receipt"
            class="btn btn-outline btn-sm mt-3"
            phx-disable-with={gettext("Opening...")}
          >
            {gettext("Start conference")}
          </button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # Confirmed *and* not reopened. Both halves matter: a line the operator has
  # asked to change reads as unresolved again, form and all.
  defp resolved?(item, editing) do
    not is_nil(item.product_id) and not MapSet.member?(editing, item.id)
  end

  # What this line has been decided to be, before it is written down: a product
  # picked out of the list, `:new` for one about to be created, or nil while the
  # question is still open. A line reopened for editing starts at whatever it
  # already says, so "Change" does not mean "start again".
  defp decided(assigns, item) do
    cond do
      Map.has_key?(assigns.chosen, item.id) -> assigns.chosen[item.id]
      creating?(assigns, item) -> :new
      item.product_id -> item.product
      true -> nil
    end
  end

  defp creating?(assigns, item), do: MapSet.member?(assigns.creating, item.id)

  defp browsing?(assigns, item), do: MapSet.member?(assigns.browsing, item.id)

  defp open_matches(socket, item_id) do
    assign(socket, :browsing, MapSet.put(socket.assigns.browsing, item_id))
  end

  defp close_matches(socket, item_id) do
    assign(socket, :browsing, MapSet.delete(socket.assigns.browsing, item_id))
  end

  defp product_label(:new), do: gettext("a new product")
  defp product_label(%{name: name}), do: name

  defp chosen_value(assigns, item) do
    case decided(assigns, item) do
      nil -> ""
      :new -> "__new__"
      product -> to_string(product.id)
    end
  end

  # What the factor currently reads as: what was typed, if anything was typed
  # and it parses, otherwise the value the invoice line already carries. A
  # factor typed to something unparsable (or emptied) falls back rather than
  # showing a price for a number that is not there.
  defp preview_factor(assigns, item) do
    case assigns.factors[item.id] do
      nil -> item.conversion_factor
      typed -> to_decimal(typed) || item.conversion_factor
    end
  end

  defp preview_unit_cost(assigns, item) do
    Invoices.unit_cost(item.commercial_unit_value, preview_factor(assigns, item))
  end

  defp blank_to(value, default) do
    case String.trim(to_string(value)) do
      "" -> default
      trimmed -> trimmed
    end
  end

  @impl true
  def handle_event("edit", %{"item" => item_id}, socket) do
    item_id = String.to_integer(item_id)

    {:noreply,
     socket
     |> assign(:editing, MapSet.put(socket.assigns.editing, item_id))
     # Reopening starts from what is actually saved, not from a factor typed
     # and abandoned the last time this line was open.
     |> assign(:factors, Map.delete(socket.assigns.factors, item_id))}
  end

  def handle_event("cancel_edit", %{"item" => item_id}, socket) do
    item_id = String.to_integer(item_id)

    {:noreply,
     socket
     |> assign(:editing, MapSet.delete(socket.assigns.editing, item_id))
     |> assign(:factors, Map.delete(socket.assigns.factors, item_id))}
  end

  # Only the price preview: nothing here is written until "resolve" submits.
  def handle_event("preview_factor", %{"item" => item_id, "conversion_factor" => factor}, socket) do
    item_id = String.to_integer(item_id)
    {:noreply, assign(socket, :factors, Map.put(socket.assigns.factors, item_id, factor))}
  end

  # Clicking into the field is the question being asked, so that is when the
  # answers appear — ranked suggestions for this line before a word is typed.
  def handle_event("open_matches", %{"item" => item_id}, socket) do
    {:noreply, open_matches(socket, String.to_integer(item_id))}
  end

  def handle_event("close_matches", %{"item" => item_id}, socket) do
    {:noreply, close_matches(socket, String.to_integer(item_id))}
  end

  def handle_event("search", %{"item" => item_id, "query" => query}, socket) do
    item_id = String.to_integer(item_id)
    products = Catalog.list_products(search: query, limit: 10)

    {:noreply,
     socket
     # Typing counts as using the field: results the operator cannot see are
     # the bug this screen was rebuilt to fix.
     |> open_matches(item_id)
     |> assign(:queries, Map.put(socket.assigns.queries, item_id, query))
     |> assign(:candidates, Map.put(socket.assigns.candidates, item_id, products))}
  end

  # Choosing, not confirming. The line still needs its conversion factor before
  # anything is written, so this only records what was picked.
  def handle_event("pick", %{"item" => item_id, "product" => product_id}, socket) do
    item_id = String.to_integer(item_id)
    product = Catalog.get_product!(product_id)

    {:noreply,
     socket
     |> assign(:chosen, Map.put(socket.assigns.chosen, item_id, product))
     |> assign(:creating, MapSet.delete(socket.assigns.creating, item_id))
     |> close_matches(item_id)}
  end

  # Reveals the name field and nothing else. The product is created when the
  # line is confirmed, so backing out here costs nothing.
  def handle_event("choose_new", %{"item" => item_id}, socket) do
    item_id = String.to_integer(item_id)

    {:noreply,
     socket
     |> assign(:creating, MapSet.put(socket.assigns.creating, item_id))
     |> assign(:chosen, Map.delete(socket.assigns.chosen, item_id))
     |> close_matches(item_id)}
  end

  def handle_event("unpick", %{"item" => item_id}, socket) do
    item_id = String.to_integer(item_id)

    {:noreply,
     socket
     # `nil` rather than a delete: a line that already carries a product must
     # fall back to "undecided", not to the product it is being changed away
     # from, or "Change" would do nothing.
     |> assign(:chosen, Map.put(socket.assigns.chosen, item_id, nil))
     |> assign(:creating, MapSet.delete(socket.assigns.creating, item_id))
     # "Change" is the question being asked again, so the answers come with it
     # rather than waiting for a second click into a field that just appeared.
     |> open_matches(item_id)}
  end

  def handle_event("resolve", %{"item" => item_id} = params, socket) do
    item = find_item(socket.assigns.invoice, item_id)
    user_id = socket.assigns.current_scope.user.id

    with {:ok, attrs} <- resolution_attrs(item, params),
         {:ok, _resolved} <- Invoices.resolve_item(item, attrs, user_id: user_id) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Item confirmed."))
       |> assign(:editing, MapSet.delete(socket.assigns.editing, item.id))
       # The picker for this line is spent. Left behind, reopening the line
       # would show a stale choice rather than what was actually saved.
       |> assign(:chosen, Map.delete(socket.assigns.chosen, item.id))
       |> assign(:creating, MapSet.delete(socket.assigns.creating, item.id))
       |> assign(:queries, Map.delete(socket.assigns.queries, item.id))
       |> assign(:factors, Map.delete(socket.assigns.factors, item.id))
       |> close_matches(item.id)
       |> assign_invoice(Invoices.get_invoice!(socket.assigns.invoice.id))}
    else
      {:error, :missing_product} ->
        {:noreply, put_flash(socket, :error, gettext("Pick a product for this item."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("This item could not be confirmed."))}
    end
  end

  def handle_event("post", %{"location_id" => location_id}, socket) do
    invoice = socket.assigns.invoice
    user_id = socket.assigns.current_scope.user.id

    case Invoices.post_invoice(invoice, %{
           location_id: String.to_integer(location_id),
           user_id: user_id
         }) do
      {:ok, %{invoice: posted, transaction: transaction}} ->
        summary = %{
          items: length(posted.items),
          units:
            transaction.entries
            |> Enum.map(& &1.quantity)
            |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
          value: posted.total,
          location: location_name(socket.assigns.locations, String.to_integer(location_id))
        }

        {:noreply,
         socket
         |> assign(:posted, summary)
         |> assign_invoice(posted)
         |> assign_receipts(posted)}

      {:error, {:unresolved_items, items}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("%{count} item(s) still need confirmation.", count: length(items))
         )}

      {:error, :already_posted} ->
        {:noreply, put_flash(socket, :error, gettext("This invoice was already posted."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The invoice could not be posted."))}
    end
  end

  def handle_event("start_receipt", _params, socket) do
    invoice = socket.assigns.invoice

    case Receiving.start_receipt(invoice, %{
           location_id: socket.assigns.location_id,
           user_id: socket.assigns.current_scope.user.id
         }) do
      {:ok, receipt} ->
        {:noreply, push_navigate(socket, to: ~p"/receipts/#{receipt}")}

      {:error, :receipt_already_open} ->
        {:noreply, put_flash(socket, :error, gettext("There is already an open conference."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The conference could not be started."))}
    end
  end

  defp receipt_status_label("draft"), do: gettext("in progress")
  defp receipt_status_label("completed"), do: gettext("closed")
  defp receipt_status_label("cancelled"), do: gettext("cancelled")

  defp total_units(invoice) do
    Enum.reduce(invoice.items, Decimal.new(0), fn item, total ->
      case item.conversion_factor do
        nil -> total
        factor -> Decimal.add(total, Decimal.mult(item.commercial_quantity, factor))
      end
    end)
  end

  defp location_name(locations, id) do
    case Enum.find(locations, &(&1.id == id)) do
      nil -> "—"
      location -> location.name
    end
  end

  defp find_item(invoice, item_id) do
    item_id = String.to_integer(item_id)
    Enum.find(invoice.items, &(&1.id == item_id))
  end

  # "__new__" creates a catalog product for an item nobody has bought before.
  # The name comes from the field the operator can edit, never straight from the
  # invoice: a catalog name outlives the invoice that introduced it, and the
  # supplier's description carries the shipment's own data inside it.
  defp resolution_attrs(item, %{"product_id" => "__new__"} = params) do
    name =
      case String.trim(params["new_product_name"] || "") do
        "" -> Catalog.suggested_product_name(item.description)
        edited -> edited
      end

    case Catalog.create_product(%{name: name, ncm: item.ncm}) do
      {:ok, product} -> {:ok, base_attrs(params, product.id)}
      {:error, _changeset} -> {:error, :invalid_product}
    end
  end

  defp resolution_attrs(_item, params) do
    case params["product_id"] do
      # Blank now means the operator pressed "Change" and picked nothing yet.
      # It used to fall back to the product already on the line, which made
      # changing a line silently confirm it as what it already was.
      value when value in [nil, ""] ->
        {:error, :missing_product}

      value ->
        {:ok, base_attrs(params, String.to_integer(value))}
    end
  end

  defp base_attrs(params, product_id) do
    %{
      product_id: product_id,
      conversion_factor: params["conversion_factor"],
      lot_number: blank_to_nil(params["lot_number"]),
      expires_on: blank_to_nil(params["expires_on"]),
      lot_source: if(blank_to_nil(params["lot_number"]), do: "manual", else: nil)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
