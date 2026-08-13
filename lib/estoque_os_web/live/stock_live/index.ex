defmodule EstoqueOSWeb.StockLive.Index do
  @moduledoc """
  What is in stock right now, with the spreadsheet escape hatch in both
  directions.

  Quantities carry a data-quality mark: a box counted long ago is *presumed*,
  not verified, and the screen says so rather than pretending otherwise.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only. The spreadsheet import posts adjustments and stays with
  operators, as does the upload validation that feeds it.
  """
  def viewer_events, do: ~w(filter page sort clear_filters)

  import EstoqueOS.Coercion

  alias EstoqueOS.Reports
  alias EstoqueOSWeb.UserAuth
  alias EstoqueOS.Inventory.Locations

  @stale_after_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Stock"))
     |> assign(:import_result, nil)
     |> assign(:import_errors, [])
     |> assign(:search, "")
     |> assign(:location_id, nil)
     |> assign(:only_expiring, false)
     |> assign(:only_controlled, false)
     |> assign(:only_needs_review, false)
     |> assign(:sort, %{key: "product", dir: :asc})
     |> assign(:page, 1)
     |> assign(:locations, Locations.list_locations())
     |> allow_upload(:sheet,
       accept: ~w(.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet),
       max_entries: 1,
       max_file_size: 16_000_000
     )}
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
     |> assign(:location_id, parse_id(params["location_id"]))
     |> assign(:only_expiring, params["expiring"] == "on")
     |> assign(:only_controlled, params["controlled"] == "on")
     |> assign(:only_needs_review, params["review"] == "on")
     |> load_rows()}
  end

  defp load_rows(socket) do
    page =
      Reports.stock_page(
        search: socket.assigns.search,
        location_id: socket.assigns.location_id,
        only_expiring: socket.assigns.only_expiring,
        only_controlled: socket.assigns.only_controlled,
        only_needs_review: socket.assigns.only_needs_review,
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
      assigns.location_id != nil,
      assigns.only_expiring,
      assigns.only_controlled,
      assigns.only_needs_review
    ]
    |> Enum.count(& &1)
  end

  defp filtering?(assigns) do
    assigns.search != "" or assigns.location_id != nil or assigns.only_expiring or
      assigns.only_controlled or assigns.only_needs_review
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
        <:actions>
          <details :if={UserAuth.operator?(@current_scope)} class="dropdown dropdown-end">
            <summary class="btn btn-outline">
              <.icon name="hero-table-cells" class="size-5" />
              {gettext("Spreadsheet")}
            </summary>
            <div class="dropdown-content z-50 mt-2 w-80 rounded-box bg-base-100 shadow-lg border border-base-300 p-4 space-y-3">
              <.spreadsheet_actions upload={@uploads.sheet} export_path={~p"/stock/export.xlsx"} />
            </div>
          </details>
        </:actions>
      </.header>

      <form id="filter-form" phx-change="filter" phx-submit="filter">
        <.toolbar>
          <label class="input flex items-center gap-2 grow min-w-64">
            <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
            <span class="sr-only">{gettext("Search")}</span>
            <input
              type="search"
              name="search"
              value={@search}
              placeholder={gettext("Product, lot, box or GTIN")}
              class="grow"
              phx-debounce="300"
            />
          </label>

          <details class="dropdown dropdown-end">
            <summary class="btn">
              <.icon name="hero-adjustments-horizontal" class="size-5" />
              {gettext("Filters")}
              <span :if={active_filters(assigns) > 0} class="badge badge-primary badge-sm">
                {active_filters(assigns)}
              </span>
            </summary>

            <div class="dropdown-content z-50 mt-2 w-72 rounded-box bg-base-100 shadow-lg border border-base-300 p-4 space-y-2">
              <label class="fieldset w-full">
                <span class="label">{gettext("Location")}</span>
                <select name="location_id" class="select w-full">
                  <option value="">{gettext("All locations")}</option>
                  <option
                    :for={location <- @locations}
                    value={location.id}
                    selected={location.id == @location_id}
                  >
                    {location.name}
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

          <p :if={filtering?(assigns)} class="text-sm text-base-content/80 basis-full">
            {gettext("%{count} position(s) match", count: @total)}
          </p>
        </.toolbar>
      </form>

      <p :if={@capped} class="alert alert-warning">
        {gettext(
          "More than %{count} positions match; narrow the search to see the rest.",
          count: @max_rows
        )}
      </p>

      <.spreadsheet_outcome result={@import_result} errors={@import_errors} />

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
            {row.lot_number || gettext("unknown")}
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
            {row.box || gettext("no box")} · {row.location}
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
            {quantity(row.quantity)}
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
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:search, params["search"] || "")
     |> assign(:location_id, parse_id(params["location_id"]))
     |> assign(:only_expiring, params["only_expiring"] == "on")
     |> assign(:only_controlled, params["only_controlled"] == "on")
     |> assign(:only_needs_review, params["only_needs_review"] == "on")
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
     |> assign(:location_id, nil)
     |> assign(:only_expiring, false)
     |> assign(:only_controlled, false)
     |> assign(:sort, %{key: "product", dir: :asc})
     |> assign(:page, 1)
     |> load_rows()}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # This screen is readable by anyone signed in, so the gate on the route is the
  # wrong one to rely on: hiding the form is presentation, and an event arrives
  # over a socket whether or not the button was ever rendered.
  def handle_event("import", _params, socket) do
    if UserAuth.operator?(socket.assigns.current_scope) do
      import_spreadsheet(socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to access this page."))}
    end
  end

  defp import_spreadsheet(socket) do
    user_id = socket.assigns.current_scope.user.id

    case consume_uploaded_entries(socket, :sheet, fn %{path: path}, _entry ->
           {:ok, path |> File.read!() |> Reports.import_stock(user_id: user_id)}
         end) do
      [{:ok, result}] ->
        {:noreply,
         socket
         |> assign(:import_result, result)
         |> assign(:import_errors, [])
         |> load_rows()}

      [{:error, errors}] when is_list(errors) ->
        {:noreply, socket |> assign(:import_errors, errors) |> assign(:import_result, nil)}

      [{:error, {:missing_columns, columns}}] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The spreadsheet is missing these columns: %{columns}",
             columns: Enum.join(columns, ", ")
           )
         )}

      [{:error, _reason}] ->
        {:noreply, put_flash(socket, :error, gettext("The spreadsheet could not be read."))}

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Pick a spreadsheet first."))}
    end
  end

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  # "Presumed" was a 10px ghost badge — the least visible thing on a screen
  # whose whole claim is that it distinguishes counted from inherited.
  defp presumed_label(%{box_verified_at: nil}), do: gettext("presumed · never counted")

  defp presumed_label(%{box_verified_at: verified_at}) do
    gettext("presumed since %{date}", date: date(verified_at))
  end

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil
  defp parse_id(value), do: String.to_integer(value)

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
