defmodule EstoqueOSWeb.HomeLive.Index do
  @moduledoc """
  The landing screen: what needs attention today.

  Ordered by what can actually hurt a mission — stock about to expire, items
  below the quantity a mission is expected to carry, boxes nobody has counted
  in a while — rather than by what is easiest to render.
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

  # A dashboard answers "is anything wrong"; the screen it links to answers
  # "what exactly". Five rows is enough to tell the difference.
  @preview 5
  @shortage_limit 12

  # The window the marketing panels read their pace over. Fixed, and not a
  # control: this screen answers "is anything wrong", and the report behind it
  # — Sales — is where a period is chosen and argued with.
  @sales_window 90

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Overview"))
     |> assign(:may_review?, may_review?(socket))
     |> assign(:may_acknowledge?, Alerts.may_acknowledge?(socket.assigns.current_scope))
     # Whether this person has a stock to choose at all. A marketing user has
     # one and only one, so they are never offered the tabs — the same rule the
     # stock list uses, and the same reason: an answer that cannot change is
     # not a question.
     |> assign(:segment_locked?, Scope.segment(socket.assigns.current_scope) != nil)}
  end

  # Which stock this overview is about, and the role always wins: `segment/2`
  # gives a marketing user their own segment whatever the address asks for, and
  # anyone who holds both stocks gets what they asked for or all of it.
  #
  # In the address rather than in an event, so the coordinator can keep the
  # marketing overview open in a tab and the reload lands on the same page.
  @impl true
  def handle_params(params, _uri, socket) do
    segment = Scope.segment(socket.assigns.current_scope, params["segment"])

    {:noreply,
     socket
     |> assign(:segment, segment)
     |> assign(:summary, Reports.summary(segment: segment))
     |> assign(:expiring, Reports.expiring_soon(limit: @preview, segment: segment))
     |> assign(:activity, Reports.recent_activity(limit: @preview, segment: segment))
     # No screen goes deeper into shortages, so this one carries its own weight
     # rather than teasing five rows and stopping.
     |> assign(:below_minimum, Reports.below_minimum(limit: @shortage_limit, segment: segment))
     |> assign_surgical_panels(segment)
     |> assign_sales_panels(segment)}
  end

  # Only the stock that is sold has a pace to read. Asking the same question of
  # the surgical stock would answer it — a mission consumes and the ledger
  # records it — but "how many days of gauze are left at this rate" is not what
  # anyone plans a mission by, and the panels would be three more things to
  # scroll past on the screen that is supposed to be short.
  defp assign_sales_panels(socket, "marketing") do
    to = Date.utc_today()

    assign(
      socket,
      :pace,
      Reports.sales_pace(Date.add(to, -@sales_window), to, segment: "marketing", limit: @preview)
    )
  end

  defp assign_sales_panels(socket, _segment), do: assign(socket, :pace, nil)

  # Boxes, disputed counts and kit readiness are the surgical operation asking
  # itself questions. A box is shared by both stocks and a count is about a box,
  # so there is no honest way to narrow them to one segment — and a marketing
  # user has nothing to do with any of it. Empty rather than filtered, and the
  # panels do not render at all.
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

  # Whose problem a disputed count is. Admin and manager: the two roles that
  # decide what to do about it — chase the supplier, or accept the loss.
  defp may_review?(socket) do
    Scope.effective_role(socket.assigns.current_scope) in User.roles_that_plan()
  end

  # Read at the warehouse the stock actually leaves from. A kit's coverage at a
  # mission site is a different question and not this one.
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
        <:subtitle>{subtitle(@segment)}</:subtitle>
      </.header>

      <!-- The two stocks share a warehouse and almost nothing else: what is
           expiring in the marketing shelf is not a mission problem, and a
           coordinator reading one number for both was reading neither. The tabs
           are the whole answer for a role that holds both stocks; a role that
           holds one never sees them and lands on their own overview. -->
      <div :if={not @segment_locked?} role="tablist" class="tabs tabs-box w-fit">
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
        <!-- Amber only while something is actually waiting. Colouring a zero
             teaches people that the colour means nothing.

             Not shown to a role that cannot open the invoices — a tile whose
             whole purpose is to be clicked, leading to a page that refuses, is
             the same dead door as the menu entry that was removed. -->
        <.stat
          :if={Layouts.may_access?(@current_scope, ~p"/invoices")}
          label={gettext("Invoices pending")}
          value={@summary.invoices_pending}
          hint={gettext("waiting for confirmation")}
          href={~p"/invoices"}
          tone={if @summary.invoices_pending > 0, do: :warn, else: :neutral}
        />

        <!-- What the shelf did, not what it holds. Only the stock that is sold
             has this pair, and it is the pair the person who orders the next
             print run reads first. -->
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

      <!-- Above everything else, and only when it is not empty. A count that was
           repeated and still disagreed is either goods leaving unrecorded or a
           count nobody can trust, and both are this person's problem.

           Only theirs, too. The operator who counted it three times already
           knows; telling them again on every visit to the dashboard is noise
           they cannot act on, and the decision — chase the supplier, or accept
           the loss — is not theirs to take. -->
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
            <!-- Straight to the thing that disagreed. A warning that states a
                 fact and stops there leaves the manager to find the row by
                 hand, which is the same as not being told.

                 Which thing depends on what was counted: a conference is about
                 a delivery, and the row a manager wants open for one of those
                 is the invoice, not the box the goods ended up in. -->
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
              <!-- "Olhei e está tudo bem." A divergence that is simply the
                   answer — the box really did have 27 — has to be closable, or
                   this list only grows and stops being read, which costs the
                   alarms that mattered. It is not an erasure: the reason stays
                   on the movement and the acknowledgement is recorded beside it
                   with a name and a date. -->
              <button
                :if={@may_acknowledge?}
                type="button"
                phx-click="acknowledge_count"
                phx-value-id={row.transaction.id}
                class="btn btn-xs btn-soft shrink-0"
              >
                {gettext("Noted")}
              </button>
            </span>
          </li>
        </ul>
      </div>

      <!-- `items-start` so a short panel keeps its own height instead of being
           stretched to match the tall one beside it, which is where the dead
           space under these lists came from. -->
      <div class="grid lg:grid-cols-2 gap-6 items-start">
        <!-- Hidden on the marketing tab while it is empty, and only there: a
             shirt has no expiry date, so "nada vencendo" is not news — it is an
             empty panel in the best corner of the screen, above the two panels
             that person actually opens this page for. A printed item that does
             carry a date still shows up here the moment it is close. -->
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

        <!-- The question before a trip is not "how much gauze is there" but "can
             we build the kits". A warehouse can look full and still not complete
             one Kit Paciente because a single cannula ran out. -->
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

        <!-- The same list under two names, because it is the same fact read by
             two people: the coordinator is short for a mission, and marketing
             has to have more made. "Missão" in the title of a panel about
             shirts was the word that gave it away. -->
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

        <!-- Which one leaves most, in units rather than in money: each shirt
             size is its own product, so this list is also the answer to which
             size to have made more of. -->
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

        <!-- The number that says *when*, which "abaixo do mínimo" only says
             after the fact. Days left at the pace of the window, so an order
             can be placed while there is still something on the shelf. -->
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

        <!-- What not to have printed again. Only what is actually on the shelf:
             something that sold out is not sitting still, and listing it here
             would read as a warning against the thing that works. -->
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

        <!-- Both hidden rather than empty for the marketing role: a box belongs
             to no segment and a disputed count is about a box, so there is no
             version of these panels that is *theirs*. Empty, this panel would
             read as "nothing to recount", which is a different statement and an
             untrue one. -->
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
                <p><Movement.movement_badge type={row.transaction.type} /></p>
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
        <!-- The stock list, filtered to exactly those lots. The count was the
             whole message before, and a number is not something anyone can act
             on. -->
        <.link navigate={~p"/stock?review=on"} class="btn btn-sm">
          {gettext("See them")}
        </.link>
      </div>
    </Layouts.app>
    """
  end

  attr :href, :string, required: true
  attr :rows, :list, required: true
  attr :label, :string, required: true
  attr :threshold, :integer, default: @preview

  # The way out of a preview, shown only once the list is actually full: with
  # four rows on screen there is nothing deeper to see, and a link that leads to
  # the same four teaches the operator to stop trusting it.
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

  # The words each stock uses for the same tile. "Catálogo" is what the
  # surgical operation calls its list of supplies; marketing calls the same
  # thing what it is for, which is being sold.
  defp catalog_label("marketing"), do: gettext("Products on sale")
  defp catalog_label(_segment), do: gettext("Catalog")

  defp value_label("marketing"), do: gettext("Value on the shelf")
  defp value_label(_segment), do: gettext("Known value")

  defp shortage_title("marketing"), do: gettext("Time to restock")
  defp shortage_title(_segment), do: gettext("Below the mission minimum")

  defp subtitle("marketing"), do: gettext("What the marketing stock needs today.")
  defp subtitle(_segment), do: gettext("What needs attention before the next mission.")

  # A week is the point where ordering still works: whatever is made has to be
  # printed, delivered and put away before the shelf is empty.
  defp cover_class(days) when days <= 7, do: "text-error"
  defp cover_class(days) when days <= 21, do: "text-warning"
  defp cover_class(_days), do: ""

  # Both stocks first, because the operation is one operation and the person
  # with the tabs is the one who has to see it whole before splitting it.
  defp segment_tabs do
    [
      {nil, gettext("All")}
      | Enum.map(Product.segments(), &{&1, StockLive.Index.segment_label(&1)})
    ]
  end

  defp overview_path(nil), do: ~p"/"
  defp overview_path(segment), do: ~p"/?segment=#{segment}"

  defp bottleneck_names(bottlenecks) do
    bottlenecks |> Enum.map(& &1.item.description) |> Enum.take(2) |> Enum.join(", ")
  end

  # Zero kits is the whole problem; one is a trip that cannot go wrong anywhere.
  @impl true
  def handle_event("acknowledge_count", %{"id" => id}, socket) do
    case Alerts.acknowledge_count(id, socket.assigns.current_scope) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> assign(:to_review, Reports.counts_needing_review(limit: @preview))
         |> put_flash(:info, gettext("Noted. The count stays on record."))}

      # `Alerts` decides, not this screen: the button is only rendered for the
      # roles that may close one, and a button nobody rendered has never been
      # what stops anything.
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
