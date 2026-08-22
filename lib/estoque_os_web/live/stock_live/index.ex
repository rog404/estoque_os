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
  def viewer_events, do: ~w(search filter page sort clear_filters drop_filter)

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
     |> assign(:situations, [])
     |> assign(:segment, nil)
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
     # The address still speaks the old language, one word per situation, so
     # every link the app already sends here keeps working: the overview's
     # "expiring soon" is `/stock?expiring=on` and now so is its "below the
     # minimum".
     |> assign(:situations, situations_from(params))
     |> assign(:segment, segment(socket, params["segment"]))
     |> load_rows()}
  end

  defp load_rows(socket) do
    page =
      Reports.stock_page(
        search: socket.assigns.search,
        location_ids: socket.assigns.location_ids,
        situations: socket.assigns.situations,
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
      assigns.segment != nil,
      assigns.situations != []
    ]
    |> Enum.count(& &1)
  end

  # One colour per kind of filter, in one place, so the chips inside the panel
  # and the chips outside it cannot drift apart. The kind is what the colour
  # says — not the urgency of the value, which the row itself already says.
  defp filter_tone("location"), do: "info"
  defp filter_tone("situation"), do: "warning"
  # Green, not the accent: the accent is an orange at hue 38 and the situation
  # amber is at 68, which is the same colour to anybody not holding a swatch.
  defp filter_tone("segment"), do: "success"
  defp filter_tone(_kind), do: "primary"

  # The filters that are on, in one list the row of chips can render: the kind
  # is what dropping it has to undo, the value is which one of that kind, and
  # the label is the word the operator picked it by.
  defp applied_filters(assigns) do
    locations =
      for id <- assigns.location_ids,
          location = Enum.find(assigns.locations, &(&1.id == id)),
          do: {"location", id, location.name}

    situations =
      for value <- assigns.situations,
          {^value, label} <- situations(),
          do: {"situation", value, label}

    segment =
      if assigns.segment,
        do: [{"segment", assigns.segment, segment_label(assigns.segment)}],
        else: []

    search = if assigns.search != "", do: [{"search", "", assigns.search}], else: []

    search ++ locations ++ situations ++ segment
  end

  defp filtering?(assigns) do
    assigns.search != "" or assigns.location_ids != [] or assigns.situations != [] or
      assigns.segment != nil
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
          {gettext("%{count} stored lot(s)", count: @total)}
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
            <!-- The icon alone. A word beside a control that is unmistakably a
                 filter was a label on a label, and this bar is shared with the
                 search box, which is what the width is for. The count stays: a
                 narrowed list must never look like the whole stock. -->
            <summary
              class="btn btn-square relative"
              aria-label={gettext("Filters")}
              title={gettext("Filters")}
            >
              <.icon name="hero-adjustments-horizontal" class="size-5" />
              <!-- Off the corner rather than beside the icon: inside a square
                   button the count squeezed the icon it belongs to. -->
              <span
                :if={active_filters(assigns) > 0}
                class="badge badge-primary badge-xs absolute -top-1.5 -right-1.5"
              >
                {active_filters(assigns)}
              </span>
            </summary>

            <div class="dropdown-content z-50 mt-2 w-80 max-w-[calc(100vw-2rem)] rounded-box bg-base-100 shadow-lg border border-base-300 p-4 space-y-2">
              <!-- One control per kind of answer, and the colour is the kind:
                   places are one tone, situations another, the stock a third.
                   Nothing ticked means everywhere, which is what an empty
                   filter should mean. -->
              <.filter_chips
                name="location_id[]"
                label={gettext("Location")}
                tone={filter_tone("location")}
                searchable_from={8}
                options={Enum.map(@locations, &{&1.id, &1.name})}
                selected={Enum.map(@location_ids, &to_string/1)}
              />

              <!-- Not rendered for a role that has only one stock. The gate is
                   `segment/2`, which ignores whatever arrives; this is only
                   about not offering a choice that does not exist. -->
              <.filter_chips
                name="segment"
                label={gettext("Stock")}
                tone={filter_tone("segment")}
                options={Enum.map(Product.segments(), &{&1, segment_label(&1)})}
                selected={List.wrap(@segment)}
              />

              <!-- The group grew two entries when it stopped being three loose
                   checkboxes. Already-expired is now its own answer: the
                   expiring window is ninety days, so it swallowed the thing
                   somebody actually came looking for. And below-the-minimum,
                   which the overview could name and this screen could not
                   filter by. -->
              <.filter_chips
                name="situation[]"
                label={gettext("Situation")}
                tone={filter_tone("situation")}
                options={situations()}
                selected={@situations}
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

        <!-- What is on, as labels, outside the panel that set them. A count of
             active filters on a closed button says how many; it never says
             which, and "which" is the question somebody asks when the list is
             shorter than they expected. Each one drops on its own. -->
        <div :if={filtering?(assigns)} class="flex flex-wrap items-center gap-1.5 basis-full">
          <.filter_pill
            :for={{kind, value, label} <- applied_filters(assigns)}
            label={label}
            tone={filter_tone(kind)}
            phx-click="drop_filter"
            phx-value-kind={kind}
            phx-value-filter={value}
          />

          <span class="text-sm text-base-content/80">
            {gettext("%{count} stored lot(s) match", count: @total)}
          </span>
        </div>
      </.toolbar>

      <p :if={@capped} class="alert alert-warning">
        {gettext(
          "More than %{count} positions match; narrow the search to see the rest.",
          count: @max_rows
        )}
      </p>

      <.panel title={gettext("Stored lots")} flush>
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

          <!-- The widest column, because it holds the longest strings on the
               screen: a real catalog name is "Compressa de gaze 7,5x7,5 estéril
               13 fios". It was sharing the width evenly with a lot number and a
               date, so the name broke over three lines — two of them the name
               and a third for the unit, which had a paragraph of its own for a
               word. The unit rides at the end of the name now, so the cell is
               two lines at worst. -->
          <:col
            :let={row}
            label={gettext("Product")}
            key="product"
            emphasis={:identity}
            width="w-[30%]"
          >
            <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
              {row.product}
            </.link>
            <span class="text-sm text-base-content/60 whitespace-nowrap">
              {row.product_stock_unit}
              <span :if={row.packagings != []}>
                · {packaging_label(row.packagings)}
              </span>
            </span>
          </:col>

          <:col :let={row} label={gettext("Lot")} key="lot" group width="w-[9%]">
            <!-- "desconhecido" is a complaint, and it is only true of goods that
                 should have carried a lot number. A t-shirt has none to read, so
                 for those the cell says nothing rather than accusing somebody of
                 not having looked. -->
            {row.lot_number || blank_lot(row)}
          </:col>

          <:col :let={row} label={gettext("Expiry")} key="expires_on" width="w-[11%]">
            <span class={expiry_class(row)}>{date(row.expires_on)}</span>
          </:col>

          <!-- One place on the row where its state is said, rather than a badge
               in whichever column happens to know one thing.

               Ranked and capped at two. Every row could wear five, and a row
               wearing five says nothing at all — what the eye needs is the
               worst thing that is true about it. Expired outranks expiring
               outranks controlled outranks running low; how it arrived comes
               last, because it is background and never urgent.

               Controlled sits above the shortage because this column is the
               only place the row says it: the badge under the product name said
               the same word twice on the same line, and it went. -->
          <:col :let={row} label={gettext("Flags")} width="w-[11%]">
            <div class="flex flex-wrap gap-1">
              <.status :for={kind <- flags(row)} kind={kind} />
            </div>
          </:col>

          <:col :let={row} label={gettext("Where")} key="box" width="w-[18%]">
            <.box_code code={row.box} />
            <!-- The mark belongs to the box, so it sits on the box: this is a
                 claim about whether the number in *that* box was ever counted.
                 It was two lines of prose under the cell — honest, and it made
                 every row of a long list a paragraph. An icon on the label it
                 qualifies, with the sentence on hover and in the accessible
                 name, says the same thing in the space of a character. -->
            <span
              :if={presumed?(row)}
              class="tooltip align-middle text-warning"
              data-tip={presumed_label(row)}
            >
              <.icon name="hero-question-mark-circle" class="size-4" />
              <span class="sr-only">{presumed_label(row)}</span>
            </span>
            <span class="block text-sm text-base-content/60">{row.location}</span>
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

          <!-- Five, which is every column before the quantity: product, lot,
               expiry, flags and where. It was four, so the total under it sat
               one column to the left of the numbers it totals — under "onde"
               with money on, and under the quantity heading with money off. -->
          <:foot span={5}>
            {gettext("%{count} stored lot(s) on this page", count: length(@rows))}
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
     |> assign(:situations, List.wrap(params["situation"]))
     # Ticking neither stock means both, and the panel is the one place that
     # can say it — so a blank answer here is the answer, not "use my default".
     |> assign(:segment, chosen_segment(params["segment"]))
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

  # One filter off, the rest as they were. Re-opening the panel to untick a
  # chip and pressing Apply again is three taps for what the chip says in one.
  def handle_event("drop_filter", %{"kind" => kind, "filter" => value}, socket) do
    {:noreply,
     socket
     |> drop_filter(kind, value)
     |> assign(:page, 1)
     |> load_rows()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:search, "")
     |> assign(:location_ids, [])
     |> assign(:situations, [])
     # Back to the stock this role works in, not to both: clearing the filters
     # returns the screen to how it opens, and it opens on one stock.
     |> assign(:segment, segment(socket, nil))
     |> assign(:sort, %{key: "product", dir: :asc})
     |> assign(:page, 1)
     |> load_rows()}
  end

  # Dropping the stock chip means "both", which is the one answer the picker
  # itself cannot give: ticking neither box means the whole operation, and the
  # chip is how somebody says that in one tap.
  defp drop_filter(socket, "search", _value), do: assign(socket, :search, "")

  defp drop_filter(socket, "location", value) do
    update(socket, :location_ids, &List.delete(&1, to_id(value)))
  end

  defp drop_filter(socket, "situation", value) do
    update(socket, :situations, &List.delete(&1, value))
  end

  defp drop_filter(socket, "segment", _value), do: assign(socket, :segment, nil)

  defp drop_filter(socket, _kind, _value), do: socket

  # The situations a row can be filtered by, in the order somebody looks for
  # them: what is already lost, what is about to be, what the law watches, what
  # a mission will be short of, and what arrived without its paperwork.
  defp situations do
    [
      {"expired", gettext("Expired")},
      {"expiring", gettext("Expiring")},
      {"controlled", gettext("Controlled")},
      {"below_minimum", gettext("Below the minimum")},
      {"review", gettext("Missing lot data")}
    ]
  end

  # The address keeps the old spelling — `?expiring=on`, `?review=on` — because
  # links already point here with it, from the overview and from the bell.
  defp situations_from(params) do
    Enum.filter(~w(expired expiring controlled below_minimum review), &checked?(params[&1]))
  end

  defp blank_lot(%{lot_expected: false}), do: "—"
  defp blank_lot(_row), do: gettext("unknown")

  # The two stocks, in the words the operation uses. `Movement` holds the
  # movement labels for the same reason: a name that lives next to the data it
  # names is a name two screens can disagree about.
  def segment_label("medical"), do: gettext("Surgical")
  def segment_label("marketing"), do: gettext("Marketing")
  def segment_label(nil), do: nil

  # The role always wins: a marketing user's segment is not a filter they chose
  # and can drop, it is the only stock they have. `Scope.segment/2` is the one
  # copy of that rule, and it also answers the chips: ticking both stocks sends
  # a list, which is not a segment, which is every stock.
  defp segment(socket, asked), do: Scope.segment(socket.assigns.current_scope, asked)

  defp chosen_segment(asked) when asked in ["medical", "marketing"], do: asked
  defp chosen_segment(_asked), do: nil

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
      # Above the shortage on purpose: with the cap at two, "controlled" is the
      # one that must not be the flag that gets dropped. It used to also sit
      # under the product name, which said the same thing twice on the same row.
      row.controlled && :controlled,
      row.below_minimum && :below_minimum,
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
