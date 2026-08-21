defmodule EstoqueOSWeb.StockLive.Index do
  @moduledoc """
  What is in stock right now.

  The spreadsheet round trip used to hang off this screen in a dropdown, which
  put "importar dados" — an act that writes counts for the whole warehouse — one
  click away from a list anybody may read. It lives under Relatórios now, on a
  page of its own.

  Quantities carry a data-quality mark: a box counted long ago is *presumed*,
  not verified, and the screen says so rather than pretending otherwise.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only. The spreadsheet import posts adjustments and stays with
  operators, as does the upload validation that feeds it.
  """
  def viewer_events, do: ~w(search filter page sort clear_filters)

  import EstoqueOS.Coercion

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Reports

  @stale_after_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Stock"))
     |> assign(:search, "")
     |> assign(:location_ids, [])
     |> assign(:only_expiring, false)
     |> assign(:only_controlled, false)
     |> assign(:only_needs_review, false)
     |> assign(:segment, nil)
     # A locked segment is not a filter the page offers: it is the only stock
     # this role has, so it neither shows as an active filter nor clears.
     |> assign(:segment_locked?, false)
     |> assign(:sort, %{key: "product", dir: :asc})
     |> assign(:page, 1)
     |> assign(:locations, Locations.list_locations())}
  end

  @doc """
  Filters can arrive in the address, so another screen can hand this one a
  question already narrowed — the overview's "expiring soon" links straight to
  the expiring stock instead of dropping the operator into 300 rows to filter
  by hand. It also makes any filtered view worth bookmarking.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:search, params["search"] || "")
     |> assign(:location_ids, parse_ids(params["location_id"] || params["location_ids"]))
     |> assign(:only_expiring, checked?(params["expiring"]))
     |> assign(:only_controlled, checked?(params["controlled"]))
     |> assign(:only_needs_review, checked?(params["review"]))
     |> assign(:segment, segment(socket, params["segment"]))
     |> assign(:segment_locked?, locked?(socket))
     |> load_rows()}
  end

  defp load_rows(socket) do
    page =
      Reports.stock_page(
        search: socket.assigns.search,
        location_ids: socket.assigns.location_ids,
        only_expiring: socket.assigns.only_expiring,
        only_controlled: socket.assigns.only_controlled,
        only_needs_review: socket.assigns.only_needs_review,
        segment: socket.assigns.segment,
        sort: socket.assigns.sort,
        page: socket.assigns.page
      )

    socket
    |> assign(:rows, page.rows)
    |> assign(:page, page.page)
    |> assign(:pages, page.pages)
    |> assign(:total, page.total)
    |> assign(:capped, page.capped)
    |> assign(:max_rows, page.max_rows)
    |> assign(:total_value, total_value(page.rows))
    |> assign(:total_quantity, total_quantity(page.rows))
  end

  # Shown on the Filters button so a narrowed view never looks like the whole
  # stock — the search box alone would hide that a location filter is on.
  defp active_filters(assigns) do
    [
      assigns.location_ids != [],
      assigns.segment != nil and not assigns.segment_locked?,
      assigns.only_expiring,
      assigns.only_controlled,
      assigns.only_needs_review
    ]
    |> Enum.count(& &1)
  end

  defp filtering?(assigns) do
    assigns.search != "" or assigns.location_ids != [] or assigns.only_expiring or
      assigns.only_controlled or assigns.only_needs_review or
      (assigns.segment != nil and not assigns.segment_locked?)
  end

  # Both totals skip nils rather than treating them as zero: a donation with no
  # informed value is unknown, and adding it in as nothing would quietly
  # understate what the page is worth.
  defp total_value(rows) do
    rows
    |> Enum.map(& &1.total)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp total_quantity(rows) do
    rows
    |> Enum.map(& &1.quantity)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Stock")}
        <:subtitle>
          {gettext("%{count} position(s)", count: @total)}
          <span :if={@sees_money?}>
            · <.amount value={money(@total_value)} /> {gettext("on this page")}
          </span>
        </:subtitle>
      </.header>

      <!-- Two forms, and the split is the point. The search box still answers as
           you type — it is how a product is found, and a product is found
           dozens of times a day. The panel does not: ticking a location, then a
           stock, then an expiry box used to reload the list three times, twice
           of them showing something nobody had asked for yet. You pick
           everything and press Aplicar. -->
      <!-- One bar, two forms: a form cannot nest inside another, and the search
           and the panel behave differently. Wrapping them in the same toolbar
           keeps that a detail of the markup rather than a second grey bar
           stacked under the first. -->
      <.toolbar>
        <form id="search-form" phx-change="search" phx-submit="search" class="grow min-w-64">
          <label class="input flex items-center gap-2 w-full">
            <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
            <span class="sr-only">{gettext("Search")}</span>
            <input
              type="search"
              name="search"
              value={@search}
              placeholder={gettext("Product, lot, box, GTIN or invoice number")}
              class="grow"
              phx-debounce="300"
            />
          </label>
        </form>

        <form id="filter-form" phx-submit="filter">
          <details class="dropdown dropdown-end">
            <summary class="btn">
              <.icon name="hero-adjustments-horizontal" class="size-5" />
              {gettext("Filters")}
              <span :if={active_filters(assigns) > 0} class="badge badge-primary badge-sm">
                {active_filters(assigns)}
              </span>
            </summary>

            <div class="dropdown-content z-50 mt-2 w-72 rounded-box bg-base-100 shadow-lg border border-base-300 p-4 space-y-2">
              <!-- Checkboxes and not a `select multiple`: this panel is opened
                   one-handed on a phone, where a multi-select is a scrolling
                   list you have to hold a modifier key to use. Nothing ticked
                   means everywhere, which is what an empty filter should
                   mean. -->
              <fieldset class="w-full">
                <legend class="label">{gettext("Location")}</legend>
                <.check
                  :for={location <- @locations}
                  name="location_id[]"
                  value={location.id}
                  label={location.name}
                  checked={location.id in @location_ids}
                />
              </fieldset>

              <!-- Not rendered for a role that has only one stock. The gate is
                   `segment/2`, which ignores whatever arrives; this is only
                   about not offering a choice that does not exist. -->
              <label :if={not @segment_locked?} class="fieldset w-full">
                <span class="label">{gettext("Stock")}</span>
                <select name="segment" class="select w-full">
                  <option value="">{gettext("Every stock")}</option>
                  <option
                    :for={segment <- Product.segments()}
                    value={segment}
                    selected={segment == @segment}
                  >
                    {segment_label(segment)}
                  </option>
                </select>
              </label>

              <.check name="only_expiring" label={gettext("Expiring")} checked={@only_expiring} />
              <.check
                name="only_controlled"
                label={gettext("Controlled")}
                checked={@only_controlled}
              />
              <.check
                name="only_needs_review"
                label={gettext("Missing lot data")}
                checked={@only_needs_review}
              />

              <.button variant="primary" class="btn-block">{gettext("Apply filters")}</.button>

              <button
                :if={filtering?(assigns)}
                type="button"
                phx-click="clear_filters"
                class="btn btn-ghost btn-block"
              >
                {gettext("Clear filters")}
              </button>
            </div>
          </details>
        </form>

        <p :if={filtering?(assigns)} class="text-sm text-base-content/80 basis-full">
          {gettext("%{count} position(s) match", count: @total)}
        </p>
      </.toolbar>

      <p :if={@capped} class="alert alert-warning">
        {gettext(
          "More than %{count} positions match; narrow the search to see the rest.",
          count: @max_rows
        )}
      </p>

      <.panel title={gettext("Positions")} flush>
        <.data_table
          rows={@rows}
          sort={@sort}
          sort_event="sort"
          row_id={&"row-#{&1.lot_id}-#{&1.box || "loose"}-#{&1.location_id}"}
        >
          <:empty>
            <.empty
              :if={filtering?(assigns)}
              title={gettext("Nothing here matches that.")}
              note={gettext("Try a wider search, or clear the filters to see the whole stock.")}
            >
              <:actions>
                <button type="button" phx-click="clear_filters" class="btn btn-primary btn-soft">
                  {gettext("Clear filters")}
                </button>
              </:actions>
            </.empty>

            <.empty
              :if={not filtering?(assigns)}
              title={gettext("Stock is empty.")}
              note={
                gettext(
                  "Nothing has been received yet. Import an invoice, or record what arrived without one."
                )
              }
            >
              <:actions>
                <.link navigate={~p"/invoices/import"} class="btn btn-primary">
                  {gettext("Import invoice")}
                </.link>
                <.link navigate={~p"/entry"} class="btn btn-primary btn-soft">
                  {gettext("Manual entry")}
                </.link>
              </:actions>
            </.empty>
          </:empty>

          <:col
            :let={row}
            label={gettext("Product")}
            key="product"
            emphasis={:identity}
          >
            <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
              {row.product}
            </.link>
            <.status :if={row.controlled} kind={:controlled} class="align-middle" />
            <p class="text-sm text-base-content/80">
              {row.product_stock_unit}
              <span :if={row.packagings != []}>
                · {packaging_label(row.packagings)}
              </span>
            </p>
          </:col>

          <:col :let={row} label={gettext("Lot")} key="lot" group width="w-[10%]">
            <!-- "desconhecido" is a complaint, and it is only true of goods that
                 should have carried a lot number. A t-shirt has none to read, so
                 for those the cell says nothing rather than accusing somebody of
                 not having looked. -->
            {row.lot_number || blank_lot(row)}
          </:col>

          <:col :let={row} label={gettext("Expiry")} key="expires_on" width="w-[13%]">
            <span class={expiry_class(row)}>{date(row.expires_on)}</span>
          </:col>

          <!-- One place on the row where its state is said, rather than a badge
               in whichever column happens to know one thing.

               Ranked and capped at two. Every row could wear five, and a row
               wearing five says nothing at all — what the eye needs is the
               worst thing that is true about it. Expired outranks expiring
               outranks running low; how it arrived comes last, because it is
               background and never urgent. -->
          <:col :let={row} label={gettext("Flags")} width="w-[13%]">
            <div class="flex flex-wrap gap-1">
              <.status :for={kind <- flags(row)} kind={kind} />
            </div>
          </:col>

          <:col :let={row} label={gettext("Where")} key="box" width="w-[24%]">
            <.box_code code={row.box} />
            <span class="text-base-content/80">{row.location}</span>
            <!-- Deliberately not a badge. This is the one claim the screen exists
                 to make — the number is what we believe, not what somebody
                 counted — and it was a 10px ghost badge once, which is how it
                 became the least visible thing on the page. Words, in the flow of
                 the cell. There is a test holding this. -->
            <p :if={presumed?(row)} class="text-sm text-base-content/80">
              {presumed_label(row)}
            </p>
          </:col>

          <:col
            :let={row}
            label={gettext("Quantity")}
            key="quantity"
            align={:right}
            emphasis={:primary}
            group
            width="w-[10%]"
          >
            <span class="figure">{quantity(row.quantity)}</span>
          </:col>

          <!-- `:if` on the slot, not on the cell: an unrendered column never
               reaches the browser, while a hidden one is still in the HTML and
               in every LiveView diff. The logistics operator is a partner
               outside the ONG and these are the ONG's purchase prices. -->
          <:col
            :let={row}
            :if={@sees_money?}
            label={gettext("Unit cost")}
            key="unit_cost"
            align={:right}
            emphasis={:muted}
          >
            <.amount value={unit_price(row.unit_cost)} />
          </:col>

          <:col :let={row} :if={@sees_money?} label={gettext("Total")} key="total" align={:right}>
            <.amount value={money(row.total)} />
          </:col>

          <:foot span={4}>
            {gettext("%{count} position(s) on this page", count: length(@rows))}
          </:foot>
          <:foot align={:right}>{quantity(@total_quantity)}</:foot>
          <:foot :if={@sees_money?} align={:right}></:foot>
          <:foot :if={@sees_money?} align={:right}>
            <.amount value={money(@total_value)} />
          </:foot>
        </.data_table>
      </.panel>

      <nav
        :if={@pages > 1}
        class="flex items-center justify-between gap-4 mt-4"
        aria-label={gettext("Pages")}
      >
        <button
          phx-click="page"
          phx-value-page={@page - 1}
          disabled={@page == 1}
          class="btn btn-sm"
        >
          {gettext("Previous")}
        </button>

        <span class="text-sm text-base-content/80">
          {gettext("Page %{page} of %{pages}", page: @page, pages: @pages)}
        </span>

        <button
          phx-click="page"
          phx-value-page={@page + 1}
          disabled={@page == @pages}
          class="btn btn-sm"
        >
          {gettext("Next")}
        </button>
      </nav>
    </Layouts.app>
    """
  end

  # A box nobody has counted recently holds what we *think* it holds.
  defp presumed?(%{box: nil}), do: false
  defp presumed?(%{box_verified_at: nil}), do: true

  defp presumed?(%{box_verified_at: verified_at}) do
    DateTime.diff(DateTime.utc_now(), verified_at, :day) > @stale_after_days
  end

  @impl true
  def handle_event("search", params, socket) do
    {:noreply,
     socket
     |> assign(:search, params["search"] || "")
     |> assign(:page, 1)
     |> load_rows()}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:location_ids, parse_ids(params["location_id"]))
     |> assign(:only_expiring, checked?(params["only_expiring"]))
     |> assign(:only_controlled, checked?(params["only_controlled"]))
     |> assign(:only_needs_review, checked?(params["only_needs_review"]))
     |> assign(:segment, segment(socket, params["segment"]))
     |> assign(:segment_locked?, locked?(socket))
     |> assign(:page, 1)
     |> load_rows()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, to_id(page) || 1) |> load_rows()}
  end

  def handle_event("sort", %{"key" => key}, socket) do
    %{key: current, dir: dir} = socket.assigns.sort
    sort = if key == current, do: %{key: key, dir: flip(dir)}, else: %{key: key, dir: :asc}

    {:noreply, socket |> assign(:sort, sort) |> assign(:page, 1) |> load_rows()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:search, "")
     |> assign(:location_ids, [])
     |> assign(:only_expiring, false)
     |> assign(:only_controlled, false)
     |> assign(:only_needs_review, false)
     # Not cleared: a marketing user has no other stock to clear it back to.
     |> assign(:segment, segment(socket, nil))
     |> assign(:sort, %{key: "product", dir: :asc})
     |> assign(:page, 1)
     |> load_rows()}
  end

  # What the page may ask for, and the role always wins. A marketing user's
  # segment is not a filter they chose and can drop — it is the only stock they
  # have — so a `segment=` in the address or in a form they hand-crafted is
  # ignored rather than obeyed.
  defp blank_lot(%{lot_expected: false}), do: "—"
  defp blank_lot(_row), do: gettext("unknown")

  # The two stocks, in the words the operation uses. `Movement` holds the
  # movement labels for the same reason: a name that lives next to the data it
  # names is a name two screens can disagree about.
  def segment_label("medical"), do: gettext("Surgical")
  def segment_label("marketing"), do: gettext("Marketing")
  def segment_label(nil), do: nil

  defp locked?(socket), do: Scope.segment(socket.assigns.current_scope) != nil

  # The role always wins: a marketing user's segment is not a filter they chose
  # and can drop, it is the only stock they have. `Scope.segment/2` is the one
  # copy of that rule.
  defp segment(socket, asked), do: Scope.segment(socket.assigns.current_scope, asked)

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  # "Presumed" was a 10px ghost badge — the least visible thing on a screen
  # whose whole claim is that it distinguishes counted from inherited.
  defp presumed_label(%{box_verified_at: nil}), do: gettext("presumed · never counted")

  defp presumed_label(%{box_verified_at: verified_at}) do
    gettext("presumed since %{date}", date: date(verified_at))
  end

  # A checkbox sends whatever `value` it carries, and `<.check>` carries "true".
  # Comparing against "on" was reading a value the browser never sends, so all
  # three filters were dead on the page while passing a test that handed the
  # event "on" by hand. Presence is the signal — an unchecked box is not
  # submitted at all — with the explicit falsy words honoured so a link, a test
  # or a future hidden input can say "off" and be believed.
  defp checked?(value), do: value not in [nil, "", "false", "off", "0"]

  # Locations arrive as a list of checkbox values, and a list of one is still a
  # list: the filter used to hold exactly one place, which meant "o que existe
  # no depósito **e** no trânsito" was two searches and a subtraction done in
  # somebody's head.
  defp parse_ids(nil), do: []
  defp parse_ids(""), do: []
  defp parse_ids(value) when is_binary(value), do: parse_ids([value])

  defp parse_ids(values) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case Integer.parse(to_string(value)) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # "CX/50" reads the way the warehouse says it out loud.
  defp packaging_label(packagings) do
    Enum.map_join(
      packagings,
      " · ",
      &"#{&1.unit}/#{Decimal.to_string(Decimal.normalize(&1.factor), :normal)}"
    )
  end

  # The order is the ranking, and `Enum.take/2` is the cap.
  #
  # "Bought" is last and is deliberately quiet: most of the warehouse was
  # bought, so it only ever surfaces on a row with nothing more pressing to
  # say. The one worth spotting is the donation — no price, different
  # paperwork.
  defp flags(row) do
    [
      row.expired && :expired,
      row.expiring && not row.expired && :expiring,
      row.below_minimum && :below_minimum,
      row.controlled && :controlled,
      is_nil(row.unit_cost) && :donation,
      not is_nil(row.unit_cost) && :bought
    ]
    |> Enum.filter(& &1)
    |> Enum.take(2)
  end

  defp expiry_class(%{expired: true}), do: "text-error"
  defp expiry_class(%{expiring: true}), do: "text-warning"
  defp expiry_class(_row), do: ""
end
