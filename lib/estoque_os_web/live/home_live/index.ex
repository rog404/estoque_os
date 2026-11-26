defmodule EstoqueOSWeb.HomeLive.Index do
  @moduledoc """
  The landing screen: what needs attention today, ordered by what can hurt a
  mission (expiring stock, items below the mission minimum, uncounted boxes).
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Alerts
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Kits
  alias EstoqueOS.Reports
  alias EstoqueOSWeb.Movement
  alias EstoqueOSWeb.StockLive

  # Five rows tell "is anything wrong"; the linked screen answers "what exactly".
  @preview 5
  @shortage_limit 12

  # Fixed, not a control: the Sales report is where a period is chosen.
  @sales_window 90

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Overview"))
     |> assign(:may_review?, may_review?(socket))
     |> assign(:may_acknowledge?, Alerts.may_acknowledge?(socket.assigns.current_scope))}
  end

  # The role wins: `Scope.segment/2` gives a marketing user their own segment
  # whatever the address says. In the address, not an event, so a reload keeps the tab.
  @impl true
  def handle_params(params, _uri, socket) do
    segment = Scope.segment(socket.assigns.current_scope, params["segment"])

    {:noreply,
     socket
     |> assign(:segment, segment)
     |> assign(:summary, Reports.summary(segment: segment))
     |> assign(:expiring, Reports.expiring_soon(limit: @preview, segment: segment))
     |> assign(:activity, Reports.recent_activity(limit: @preview, segment: segment))
     # No screen goes deeper into shortages, so this one lists more rows.
     |> assign(:below_minimum, Reports.below_minimum(limit: @shortage_limit, segment: segment))
     |> assign_surgical_panels(segment)
     |> assign_sales_panels(segment)}
  end

  # Only the stock that is sold has a pace to read; surgical stock is not planned by it.
  defp assign_sales_panels(socket, "marketing") do
    to = Date.utc_today()

    assign(
      socket,
      :pace,
      Reports.sales_pace(Date.add(to, -@sales_window), to, segment: "marketing", limit: @preview)
    )
  end

  defp assign_sales_panels(socket, _segment), do: assign(socket, :pace, nil)

  # Boxes are shared by both stocks, so these cannot be narrowed to one segment:
  # empty for marketing, and the panels do not render.
  defp assign_surgical_panels(socket, "marketing") do
    socket
    |> assign(:stale_boxes, [])
    |> assign(:to_review, [])
    |> assign(:readiness, [])
  end

  defp assign_surgical_panels(socket, _segment) do
    socket
    |> assign(:stale_boxes, Reports.stale_boxes(limit: @preview))
    |> assign(:to_review, Reports.counts_needing_review(limit: @preview))
    |> assign_readiness()
  end

  # A disputed count is for the roles that decide: chase the supplier or accept the loss.
  defp may_review?(socket) do
    Scope.effective_role(socket.assigns.current_scope) in User.roles_that_plan()
  end

  # Read at the warehouse the stock leaves from, not at a mission site.
  defp assign_readiness(socket) do
    case Locations.default_location() do
      nil -> assign(socket, :readiness, [])
      location -> assign(socket, :readiness, Kits.readiness(location.id))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Overview")}
      </.header>

      <div role="tablist" class="tabs tabs-box w-fit">
        <.link
          :for={{value, label} <- segment_tabs()}
          patch={overview_path(value)}
          role="tab"
          aria-selected={to_string(@segment == value)}
          class={["tab", @segment == value && "tab-active"]}
        >
          {label}
        </.link>
      </div>

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat
          label={catalog_label(@segment)}
          value={@summary.products}
          hint={gettext("active products")}
        />
        <.stat
          label={gettext("In stock")}
          value={quantity(@summary.units)}
          hint={gettext("units in %{count} lot(s)", count: @summary.positions)}
        />
        <.stat
          :if={@sees_money?}
          label={value_label(@segment)}
          value={money(@summary.known_value)}
          money
          hint={gettext("donations without a value are not counted")}
        />
        <%!-- Amber only while something is waiting. Hidden from roles that cannot open invoices: a tile leading to a refusal is a dead door. --%>
        <.stat
          :if={Layouts.may_access?(@current_scope, ~p"/invoices")}
          label={gettext("Invoices pending")}
          value={@summary.invoices_pending}
          hint={gettext("waiting for confirmation")}
          href={~p"/invoices"}
          tone={if @summary.invoices_pending > 0, do: :warn, else: :neutral}
        />

        <.stat
          :if={@pace}
          label={gettext("Sold in %{days} days", days: sales_window())}
          value={quantity(@pace.totals.quantity)}
          hint={gettext("units out the door")}
          href={~p"/reports/sales"}
        />
        <.stat
          :if={@pace && @sees_money?}
          label={gettext("Revenue in %{days} days", days: sales_window())}
          value={money(@pace.totals.revenue)}
          money
          hint={gettext("what the sales brought in")}
          href={~p"/reports/sales"}
        />
      </div>

      <%!-- Above everything, only when non-empty, and only for roles that decide (the counter already knows). --%>
      <div
        :if={@may_review? and @to_review != []}
        class="alert alert-warning flex-col items-start gap-2"
      >
        <p class="font-semibold">
          {gettext("%{count} count(s) were repeated and still disagree",
            count: length(@to_review)
          )}
        </p>
        <ul class="text-sm w-full divide-y divide-warning/20">
          <li :for={row <- @to_review} class="py-1 flex flex-wrap justify-between gap-x-4">
            <%!-- Link to what disagreed: the invoice for a conference, the box otherwise. --%>
            <.link
              :if={row.invoice}
              navigate={~p"/invoices/#{row.invoice.id}"}
              class="link link-hover font-medium"
            >
              {gettext("Invoice %{number}", number: row.invoice.number)} · {Enum.join(
                row.products,
                ", "
              )}
            </.link>
            <.link
              :if={is_nil(row.invoice) and row.box_id}
              navigate={~p"/boxes/#{row.box_id}"}
              class="link link-hover font-medium"
            >
              {gettext("Box %{box}", box: row.box)} · {Enum.join(row.products, ", ")}
            </.link>
            <span :if={is_nil(row.invoice) and is_nil(row.box_id)}>
              {gettext("Loose stock")} · {Enum.join(row.products, ", ")}
            </span>
            <span class="opacity-80 flex items-center gap-2">
              <span>
                {datetime(row.transaction.occurred_at)}
                <span :if={row.transaction.user}>· {row.transaction.user.email}</span>
              </span>
              <%!-- Acknowledging is not an erasure: the reason stays on the movement and the acknowledgement is recorded beside it. --%>
              <button
                :if={@may_acknowledge?}
                type="button"
                phx-click="acknowledge_count"
                phx-value-id={row.transaction.id}
                class="btn btn-primary btn-soft btn-xs shrink-0"
              >
                {gettext("Noted")}
              </button>
            </span>
          </li>
        </ul>
      </div>

      <div class="grid lg:grid-cols-2 gap-6 items-start">
        <%!-- Hidden on the marketing tab while empty: shirts do not expire, so an empty panel is noise. --%>
        <.panel :if={@segment != "marketing" or @expiring != []} title={gettext("Expiring soon")}>
          <p :if={@expiring == []} class="text-sm opacity-70">
            {gettext("Nothing expiring in the alert window.")}
          </p>

          <ul :if={@expiring != []} class="divide-y divide-base-200">
            <li :for={row <- @expiring} class="py-2 flex items-baseline justify-between gap-3">
              <div class="min-w-0">
                <p class="truncate">{row.product}</p>
                <p class="text-xs opacity-60">
                  {gettext("lot %{lot}", lot: row.lot_number || gettext("unknown"))} · {row.location}
                </p>
              </div>
              <div class="text-right shrink-0">
                <p class="tabular-nums">{quantity(row.quantity)}</p>
                <p class={["text-xs", expiry_class(row.days_left)]}>
                  {expiry_label(row.days_left, row.expires_on)}
                </p>
              </div>
            </li>
          </ul>

          <.more
            rows={@expiring}
            href={~p"/stock?expiring=on"}
            label={gettext("See all expiring stock")}
          />
        </.panel>

        <.panel :if={@segment != "marketing"} title={gettext("Ready for the next mission")}>
          <p :if={@readiness == []} class="text-sm opacity-70">
            {gettext("No kit registered yet.")}
          </p>

          <ul :if={@readiness != []} class="divide-y divide-base-200">
            <li :for={row <- @readiness} class="py-2 flex items-baseline justify-between gap-3">
              <div class="min-w-0">
                <p class="truncate">
                  <.link navigate={~p"/kits/#{row.kit.id}"} class="link link-hover">
                    {row.kit.name}
                  </.link>
                </p>
                <p :if={row.bottlenecks != []} class="text-xs opacity-60 truncate">
                  {gettext("held back by: %{items}", items: bottleneck_names(row.bottlenecks))}
                </p>
                <p :if={row.unresolved > 0} class="text-xs text-warning">
                  {gettext("%{count} component(s) not linked to a product yet",
                    count: row.unresolved
                  )}
                </p>
              </div>
              <div class="text-right shrink-0">
                <p class={["text-lg font-semibold tabular-nums", coverage_class(row.possible)]}>
                  {quantity(row.possible)}
                </p>
                <p class="text-xs opacity-60">{gettext("possible")}</p>
              </div>
            </li>
          </ul>
        </.panel>

        <.panel title={shortage_title(@segment)}>
          <p :if={@below_minimum == []} class="text-sm opacity-70">
            {gettext("Every product with a defined minimum is covered.")}
          </p>

          <ul :if={@below_minimum != []} class="divide-y divide-base-200">
            <li :for={row <- @below_minimum} class="py-2 flex items-baseline justify-between gap-3">
              <div class="min-w-0">
                <p class="truncate">
                  <.link navigate={~p"/products/#{row.product.id}"} class="link link-hover">
                    {row.product.name}
                  </.link>
                </p>
                <p class="text-xs opacity-60">{row.product.sector}</p>
              </div>
              <div class="text-right shrink-0">
                <p class="tabular-nums">
                  {quantity(row.quantity)} / {quantity(row.minimum)}
                </p>
                <p class="text-xs text-warning">
                  {gettext("%{count} missing", count: quantity(row.missing))}
                </p>
              </div>
            </li>
          </ul>
        </.panel>

        <.panel :if={@pace} title={gettext("Best sellers")}>
          <p :if={@pace.best_sellers == []} class="text-sm opacity-70">
            {gettext("Nothing was sold in the last %{days} days.", days: sales_window())}
          </p>

          <ul :if={@pace.best_sellers != []} class="divide-y divide-base-200">
            <li
              :for={row <- @pace.best_sellers}
              class="py-2 flex items-baseline justify-between gap-3"
            >
              <div class="min-w-0">
                <p class="truncate">
                  <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
                    {row.product}
                  </.link>
                </p>
              </div>
              <div class="text-right shrink-0">
                <p class="tabular-nums">{quantity(row.quantity)}</p>
                <p :if={@sees_money?} class="text-xs opacity-60">{money(row.revenue)}</p>
              </div>
            </li>
          </ul>

          <.more
            rows={@pace.best_sellers}
            href={~p"/reports/sales"}
            label={gettext("See the whole sales report")}
          />
        </.panel>

        <.panel :if={@pace} title={gettext("Runs out first")}>
          <p :if={@pace.cover == []} class="text-sm opacity-70">
            {gettext("Nothing on the shelf has sold in the last %{days} days.",
              days: sales_window()
            )}
          </p>

          <ul :if={@pace.cover != []} class="divide-y divide-base-200">
            <li :for={row <- @pace.cover} class="py-2 flex items-baseline justify-between gap-3">
              <div class="min-w-0">
                <p class="truncate">
                  <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
                    {row.product}
                  </.link>
                </p>
                <p class="text-xs opacity-60">
                  {gettext("%{count} sold in %{days} days",
                    count: quantity(row.sold),
                    days: sales_window()
                  )}
                </p>
              </div>
              <div class="text-right shrink-0">
                <p class={["text-lg font-semibold tabular-nums", cover_class(row.days)]}>
                  {row.days}
                </p>
                <p class="text-xs opacity-60">{gettext("day(s) left")}</p>
              </div>
            </li>
          </ul>
        </.panel>

        <.panel :if={@pace} title={gettext("Not moving")}>
          <p :if={@pace.idle == []} class="text-sm opacity-70">
            {gettext("Everything on the shelf sold at least once.")}
          </p>

          <ul :if={@pace.idle != []} class="divide-y divide-base-200">
            <li :for={row <- @pace.idle} class="py-2 flex items-baseline justify-between gap-3">
              <div class="min-w-0">
                <p class="truncate">
                  <.link navigate={~p"/products/#{row.product_id}"} class="link link-hover">
                    {row.product}
                  </.link>
                </p>
                <p class="text-xs opacity-60">
                  {gettext("no sale in %{days} days", days: sales_window())}
                </p>
              </div>
              <div class="text-right shrink-0">
                <p class="tabular-nums">{quantity(row.quantity)}</p>
                <p class="text-xs opacity-60">{gettext("on the shelf")}</p>
              </div>
            </li>
          </ul>
        </.panel>

        <%!-- Hidden, not empty, for marketing: an empty panel would falsely say "nothing to recount". --%>
        <.panel :if={@segment != "marketing"} title={gettext("Boxes to recount")}>
          <p :if={@stale_boxes == []} class="text-sm opacity-70">
            {gettext("No box is waiting on a count.")}
          </p>

          <ul :if={@stale_boxes != []} class="divide-y divide-base-200">
            <li :for={box <- @stale_boxes} class="py-2 flex items-baseline justify-between gap-3">
              <div>
                <p><.box_code code={box.box} /></p>
                <p class="text-xs opacity-60">{box.location}</p>
              </div>
              <div class="text-right">
                <p class="tabular-nums">{quantity(box.quantity)}</p>
                <p class="text-xs opacity-60">{verified_label(box.last_verified_at)}</p>
              </div>
            </li>
          </ul>

          <.more rows={@stale_boxes} href={~p"/boxes"} label={gettext("See all boxes")} />
        </.panel>

        <.panel title={gettext("Recent activity")} class="lg:col-span-2">
          <p :if={@activity == []} class="text-sm opacity-70">
            {gettext("Nothing has moved yet. Import an invoice to start.")}
          </p>

          <ul :if={@activity != []} class="divide-y divide-base-200">
            <li :for={row <- @activity} class="py-2 flex items-baseline justify-between gap-3">
              <div class="min-w-0">
                <p><Movement.movement_badge movement={row.transaction} /></p>
                <p :if={Movement.detail(row.transaction)} class="text-sm truncate">
                  {Movement.detail(row.transaction)}
                </p>
                <p class="text-xs opacity-60">
                  {datetime(row.transaction.occurred_at)}
                  <span :if={row.transaction.user}>· {row.transaction.user.email}</span>
                </p>
              </div>
              <div class="text-right shrink-0">
                <p class="tabular-nums">{quantity(row.units)}</p>
                <p class="text-xs opacity-60">
                  {gettext("%{count} line(s)", count: row.lines)}
                </p>
              </div>
            </li>
          </ul>

          <.more
            rows={@activity}
            href={~p"/reports/audit"}
            label={gettext("See the full movement log")}
          />
        </.panel>
      </div>

      <div :if={@summary.lots_needing_review > 0} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          {gettext("%{count} lot(s) came in without lot data and still need review.",
            count: @summary.lots_needing_review
          )}
        </span>
        <.button navigate={~p"/stock?review=on"} class="btn-sm">
          {gettext("See them")}
        </.button>
      </div>
    </Layouts.app>
    """
  end

  attr :href, :string, required: true
  attr :rows, :list, required: true
  attr :label, :string, required: true
  attr :threshold, :integer, default: @preview

  # Shown only once the list is full: a link to the same four rows loses trust.
  defp more(assigns) do
    ~H"""
    <div :if={length(@rows) >= @threshold} class="flex justify-end mt-3 pt-3 border-t border-base-200">
      <.link navigate={@href} class="link link-hover text-sm">
        {@label} <span aria-hidden="true">→</span>
      </.link>
    </div>
    """
  end

  def sales_window, do: @sales_window

  # Each stock's own words for the same tile.
  defp catalog_label("marketing"), do: gettext("Products on sale")
  defp catalog_label(_segment), do: gettext("Catalog")

  defp value_label("marketing"), do: gettext("Value on the shelf")
  defp value_label(_segment), do: gettext("Known value")

  defp shortage_title("marketing"), do: gettext("Time to restock")
  defp shortage_title(_segment), do: gettext("Below the mission minimum")

  # A week is where ordering still works: printing, delivery and putaway take time.
  defp cover_class(days) when days <= 7, do: "text-error"
  defp cover_class(days) when days <= 21, do: "text-warning"
  defp cover_class(_days), do: ""

  # Both stocks first: whoever holds both sees the whole operation before splitting it.
  defp segment_tabs do
    [
      {nil, gettext("All")}
      | Enum.map(Product.segments(), &{&1, StockLive.Index.segment_label(&1)})
    ]
  end

  # "All" must be explicit: with a per-role default, no `segment=` means "my stock".
  defp overview_path(nil), do: ~p"/?segment=all"
  defp overview_path(segment), do: ~p"/?segment=#{segment}"

  defp bottleneck_names(bottlenecks) do
    bottlenecks |> Enum.map(& &1.item.description) |> Enum.take(2) |> Enum.join(", ")
  end

  @impl true
  def handle_event("acknowledge_count", %{"id" => id}, socket) do
    case Alerts.acknowledge_count(id, socket.assigns.current_scope) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> assign(:to_review, Reports.counts_needing_review(limit: @preview))
         |> put_flash(:info, gettext("Noted. The count stays on record."))}

      # `Alerts` decides, not the screen: hiding the button is not the gate.
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You don't have permission to do that."))}
    end
  end

  defp coverage_class(possible) do
    cond do
      Decimal.compare(possible, 0) != :gt -> "text-error"
      Decimal.compare(possible, 2) == :lt -> "text-warning"
      true -> ""
    end
  end

  defp expiry_class(days) when days < 0, do: "text-error font-medium"
  defp expiry_class(days) when days <= 30, do: "text-error"
  defp expiry_class(_days), do: "text-warning"

  defp expiry_label(days, date) when days < 0 do
    gettext("expired on %{date}", date: date(date))
  end

  defp expiry_label(days, date) do
    gettext("%{days} day(s) · %{date}", days: days, date: date(date))
  end

  defp verified_label(nil), do: gettext("never counted")

  defp verified_label(datetime) do
    gettext("counted on %{date}", date: date(DateTime.to_date(datetime)))
  end
end
