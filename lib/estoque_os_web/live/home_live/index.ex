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
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Kits
  alias EstoqueOS.Reports
  alias EstoqueOSWeb.Movement

  # A dashboard answers "is anything wrong"; the screen it links to answers
  # "what exactly". Five rows is enough to tell the difference.
  @preview 5
  @shortage_limit 12

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Overview"))
     |> assign(:summary, Reports.summary())
     |> assign(:expiring, Reports.expiring_soon(limit: @preview))
     |> assign(:stale_boxes, Reports.stale_boxes(limit: @preview))
     |> assign(:activity, Reports.recent_activity(limit: @preview))
     |> assign(:to_review, Reports.counts_needing_review(limit: @preview))
     |> assign(:may_review?, may_review?(socket))
     # No screen goes deeper into shortages, so this one carries its own weight
     # rather than teasing five rows and stopping.
     |> assign(:below_minimum, Reports.below_minimum(limit: @shortage_limit))
     |> assign_readiness()}
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
        <:subtitle>{gettext("What needs attention before the next mission.")}</:subtitle>
      </.header>

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat
          label={gettext("Catalog")}
          value={@summary.products}
          hint={gettext("active products")}
        />
        <.stat
          label={gettext("In stock")}
          value={quantity(@summary.units)}
          hint={gettext("units in %{count} position(s)", count: @summary.positions)}
        />
        <.stat
          :if={@sees_money?}
          label={gettext("Known value")}
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
            <span class="opacity-80">
              {datetime(row.transaction.occurred_at)}
              <span :if={row.transaction.user}>· {row.transaction.user.email}</span>
            </span>
          </li>
        </ul>
      </div>

      <!-- `items-start` so a short panel keeps its own height instead of being
           stretched to match the tall one beside it, which is where the dead
           space under these lists came from. -->
      <div class="grid lg:grid-cols-2 gap-6 items-start">
        <.panel title={gettext("Expiring soon")}>
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
        <.panel title={gettext("Ready for the next mission")}>
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

        <.panel title={gettext("Below the mission minimum")}>
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

        <.panel title={gettext("Boxes to recount")}>
          <p :if={@stale_boxes == []} class="text-sm opacity-70">
            {gettext("No box is waiting on a count.")}
          </p>

          <ul :if={@stale_boxes != []} class="divide-y divide-base-200">
            <li :for={box <- @stale_boxes} class="py-2 flex items-baseline justify-between gap-3">
              <div>
                <p class="font-medium">{box.box}</p>
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

  defp bottleneck_names(bottlenecks) do
    bottlenecks |> Enum.map(& &1.item.description) |> Enum.take(2) |> Enum.join(", ")
  end

  # Zero kits is the whole problem; one is a trip that cannot go wrong anywhere.
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
