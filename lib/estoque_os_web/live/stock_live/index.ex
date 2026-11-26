defmodule EstoqueOSWeb.StockLive.Index do
  @moduledoc """
  What is in stock right now. Quantities carry a data-quality mark: a box
  counted long ago is *presumed*, not verified.
  """

  use EstoqueOSWeb, :live_view

  # Events a viewer may send; everything else is refused. Reporting only.
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

  # Filters arrive in the address so other screens can link to a narrowed view.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:search, params["search"] || "")
     |> assign(:location_ids, parse_ids(params["location_id"] || params["location_ids"]))
     # One word per situation (`?expiring=on`), so existing links keep working.
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

  # Counted on the Filters button so a narrowed view never looks like the whole stock.
  defp active_filters(assigns) do
    [
      assigns.location_ids != [],
      assigns.segment != nil,
      assigns.situations != []
    ]
    |> Enum.count(& &1)
  end

  # One colour per kind of filter, so chips inside and outside the panel agree.
  defp filter_tone("location"), do: "info"
  defp filter_tone("situation"), do: "warning"
  # Green, not the accent: accent orange (hue 38) and situation amber (68) look the same.
  defp filter_tone("segment"), do: "success"
  defp filter_tone(_kind), do: "primary"

  # {kind, value, label}: the kind is what dropping it undoes.
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

  # Both totals skip nils, not zero: an uninformed donation value is unknown.
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

      <%!-- Two forms in one bar (forms cannot nest): search answers as you type, while the filter panel applies only on submit so ticking several boxes does not reload the list each time. --%>
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
            <summary
              class="btn btn-square relative"
              aria-label={gettext("Filters")}
              title={gettext("Filters")}
            >
              <.icon name="hero-adjustments-horizontal" class="size-5" />
              <span
                :if={active_filters(assigns) > 0}
                class="badge badge-primary badge-xs absolute -top-1.5 -right-1.5"
              >
                {active_filters(assigns)}
              </span>
            </summary>

            <div class="dropdown-content z-50 mt-2 w-80 max-w-[calc(100vw-2rem)] rounded-box bg-base-100 shadow-lg border border-base-300 p-4 space-y-2">
              <.filter_chips
                name="location_id[]"
                label={gettext("Location")}
                tone={filter_tone("location")}
                searchable_from={8}
                options={Enum.map(@locations, &{&1.id, &1.name})}
                selected={Enum.map(@location_ids, &to_string/1)}
              />

              <.filter_chips
                name="segment"
                label={gettext("Stock")}
                tone={filter_tone("segment")}
                options={Enum.map(Product.segments(), &{&1, segment_label(&1)})}
                selected={List.wrap(@segment)}
              />

              <.filter_chips
                name="situation[]"
                label={gettext("Situation")}
                tone={filter_tone("situation")}
                options={situations()}
                selected={@situations}
              />

              <.button variant="primary" class="btn-block">{gettext("Apply filters")}</.button>

              <.button
                :if={filtering?(assigns)}
                variant="ghost"
                type="button"
                phx-click="clear_filters"
                class="btn-block"
              >
                {gettext("Clear filters")}
              </.button>
            </div>
          </details>
        </form>

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
                <.button type="button" phx-click="clear_filters">
                  {gettext("Clear filters")}
                </.button>
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
                <.button navigate={~p"/invoices/import"} variant="primary">
                  {gettext("Import invoice")}
                </.button>
                <.button navigate={~p"/entry"}>
                  {gettext("Manual entry")}
                </.button>
              </:actions>
            </.empty>
          </:empty>

          <%!-- Widest column: catalog names are the longest strings here; the unit rides at the end of the name so the cell is two lines at worst. --%>
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
            <%!-- "unknown" only applies to goods that should carry a lot number; a t-shirt shows nothing. --%>
            {row.lot_number || blank_lot(row)}
          </:col>

          <:col :let={row} label={gettext("Expiry")} key="expires_on" width="w-[11%]">
            <span class={expiry_class(row)}>{date(row.expires_on)}</span>
          </:col>

          <:col :let={row} label={gettext("Flags")} width="w-[11%]">
            <div class="flex flex-wrap gap-1">
              <.status :for={kind <- flags(row)} kind={kind} />
            </div>
          </:col>

          <:col :let={row} label={gettext("Where")} key="box" width="w-[18%]">
            <.box_code code={row.box} />
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

          <%!-- `:if` on the slot, not the cell: a hidden column still ships to the browser, and these are the ONG's purchase prices. --%>
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

          <%!-- Span five: every column before the quantity, so totals sit under their numbers. --%>
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
        <.button
          phx-click="page"
          phx-value-page={@page - 1}
          disabled={@page == 1}
          class="btn-sm"
        >
          {gettext("Previous")}
        </.button>

        <span class="text-sm text-base-content/80">
          {gettext("Page %{page} of %{pages}", page: @page, pages: @pages)}
        </span>

        <.button
          phx-click="page"
          phx-value-page={@page + 1}
          disabled={@page == @pages}
          class="btn-sm"
        >
          {gettext("Next")}
        </.button>
      </nav>
    </Layouts.app>
    """
  end

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
     # Neither ticked means both: a blank answer is the answer, not "use my default".
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
     # Back to the role's own stock, how the screen opens.
     |> assign(:segment, segment(socket, nil))
     |> assign(:sort, %{key: "product", dir: :asc})
     |> assign(:page, 1)
     |> load_rows()}
  end

  # Dropping the stock chip means "both".
  defp drop_filter(socket, "search", _value), do: assign(socket, :search, "")

  defp drop_filter(socket, "location", value) do
    update(socket, :location_ids, &List.delete(&1, to_id(value)))
  end

  defp drop_filter(socket, "situation", value) do
    update(socket, :situations, &List.delete(&1, value))
  end

  defp drop_filter(socket, "segment", _value), do: assign(socket, :segment, nil)

  defp drop_filter(socket, _kind, _value), do: socket

  defp situations do
    [
      {"expired", gettext("Expired")},
      {"expiring", gettext("Expiring")},
      {"controlled", gettext("Controlled")},
      {"below_minimum", gettext("Below the minimum")},
      {"review", gettext("Missing lot data")}
    ]
  end

  # The address keeps the `?expiring=on` spelling: overview and bell links use it.
  defp situations_from(params) do
    Enum.filter(~w(expired expiring controlled below_minimum review), &checked?(params[&1]))
  end

  defp blank_lot(%{lot_expected: false}), do: "—"
  defp blank_lot(_row), do: gettext("unknown")

  def segment_label("medical"), do: gettext("Surgical")
  def segment_label("marketing"), do: gettext("Marketing")
  def segment_label(nil), do: nil

  # The role always wins: a marketing user's segment is their only stock, not a
  # droppable filter. `Scope.segment/2` is the one copy of that rule.
  defp segment(socket, asked), do: Scope.segment(socket.assigns.current_scope, asked)

  defp chosen_segment(asked) when asked in ["medical", "marketing"], do: asked
  defp chosen_segment(_asked), do: nil

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  defp presumed_label(%{box_verified_at: nil}), do: gettext("presumed · never counted")

  defp presumed_label(%{box_verified_at: verified_at}) do
    gettext("presumed since %{date}", date: date(verified_at))
  end

  # `<.check>` sends "true", never "on". Presence is the signal (an unchecked box
  # is not submitted); explicit falsy words are honoured for links and tests.
  defp checked?(value), do: value not in [nil, "", "false", "off", "0"]

  # Locations arrive as a list of checkbox values, possibly of one.
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

  defp packaging_label(packagings) do
    Enum.map_join(
      packagings,
      " · ",
      &"#{&1.unit}/#{Decimal.to_string(Decimal.normalize(&1.factor), :normal)}"
    )
  end

  # The order is the ranking and `Enum.take/2` the cap at two: a row wearing five
  # flags says nothing. "Bought" is last and quiet; the donation is the one to spot.
  defp flags(row) do
    [
      row.expired && :expired,
      row.expiring && not row.expired && :expiring,
      # Above the shortage on purpose: with the cap at two, "controlled" must not be dropped.
      row.controlled && :controlled,
      row.below_minimum && :below_minimum,
      arrival_flag(row)
    ]
    |> Enum.filter(& &1)
    |> Enum.take(2)
  end

  # How it arrived, as one flag. Migrated stock has no cost either, but it is not
  # a donation, so it is told apart before the cost falls back to "donation".
  defp arrival_flag(%{arrived_by: :migration}), do: :migration
  defp arrival_flag(%{unit_cost: nil}), do: :donation
  defp arrival_flag(_row), do: :bought

  defp expiry_class(%{expired: true}), do: "text-error"
  defp expiry_class(%{expiring: true}), do: "text-warning"
  defp expiry_class(_row), do: ""
end
