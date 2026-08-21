defmodule EstoqueOSWeb.ProductLive.Show do
  @moduledoc """
  One product: where it is now, what was paid for it, and everything that ever
  moved it.

  This is the screen a recall needs. "Which lot of that gauze went to Tefé" was
  previously answerable only by reading the stock list, the invoices and the
  audit report and joining them by eye — three screens, none of them about the
  product.

  The price history is given its own block. The unit price is the number this
  whole system exists to produce, and an average hides the thing worth seeing: a
  price that doubled between two invoices is a conversation with a supplier.
  """

  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Reporting only.
  """
  def viewer_events, do: ~w()

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Catalog
  import EstoqueOS.Coercion, only: [to_id: 1]

  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Reports.ProductHistory
  alias EstoqueOSWeb.Movement

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    history = ProductHistory.for_product(id)

    if hidden_from?(socket.assigns.current_scope, history.product) do
      # A role confined to one stock has no business reading a product from the
      # other one, and this page is reachable by id from anywhere — a link, a
      # bookmark, a typed number. The list screens filter; this is the one that
      # has to refuse.
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have permission to access this page."))
       |> push_navigate(to: ~p"/stock")}
    else
      mount_product(socket, history)
    end
  end

  # A code from the same location, because a fixed example is a code standing
  # somewhere else — which is the one answer this field must not suggest.
  defp placeholder_box([%{code: code} | _rest]), do: code
  defp placeholder_box(_none), do: nil

  # `create: false` on purpose. Creating a box is an act with a place in it —
  # which warehouse, written on which box in marker pen — and the box screen is
  # where that conversation already happens. From here, an unknown code is a
  # typo far more often than it is a new box.
  defp stow(socket, lot_id, location_id, params) do
    case Locations.resolve_box(params["box_code"], location_id, create: false) do
      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, gettext("Say which box it goes into."))}

      {:ok, box} ->
        put_away(socket, box, lot_id, params["quantity"])

      {:unknown, code} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No box %{code} here. Create it on the boxes screen first.", code: code)
         )}

      {:error, {:box_elsewhere, elsewhere}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Box %{code} is somewhere else. Move it first, or use another.",
             code: elsewhere.code
           )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That could not be stored."))}
    end
  end

  defp put_away(socket, box, lot_id, quantity) do
    scope = socket.assigns.current_scope

    case Locations.put_in_box(box, lot_id, quantity, user_id: scope.user.id) do
      {:ok, _transaction} ->
        history = ProductHistory.for_product(socket.assigns.history.product.id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Stored in %{box}.", box: box.code))
         |> assign_positions(history)}

      {:error, {:insufficient_stock, %{available: available}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("There is only %{available} loose here.", available: quantity(available))
         )}

      {:error, :invalid_quantity} ->
        {:noreply, put_flash(socket, :error, gettext("Type a quantity greater than zero."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("That could not be stored."))}
    end
  end

  defp hidden_from?(scope, product) do
    case Scope.segment(scope) do
      nil -> false
      segment -> product.segment != segment
    end
  end

  defp mount_product(socket, history) do
    {:ok,
     socket
     |> assign(:page_title, history.product.name)
     |> assign(
       :cost,
       EstoqueOS.Inventory.average_cost_by_product([history.product.id])[id_of(history)]
     )
     |> assign(:changes, Catalog.product_changes(history.product.id))
     |> assign(:may_box?, may_box?(socket.assigns.current_scope))
     |> assign_positions(history)}
  end

  # The loose lines carry the boxes of their own location, because the box a
  # lot may go into is one standing in the same place. Grouped by location so a
  # product sitting loose in two warehouses offers each one its own list.
  defp assign_positions(socket, history) do
    boxes =
      history.positions
      |> Enum.filter(&is_nil(&1.box_id))
      |> Enum.map(& &1.location_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Locations.list_boxes(&1)})

    socket
    |> assign(:history, history)
    |> assign(:boxes_at, boxes)
  end

  # Marketing writes, and still not here: the boxes belong to the surgical
  # operation and every screen about them is already closed to that role. This
  # page is the one place the two meet, so it asks the question itself.
  defp may_box?(scope) do
    EstoqueOSWeb.UserAuth.role_may_write?(scope) and
      Scope.effective_role(scope) in User.roles_that_box()
  end

  # A third question, and not a rung above `@writable?`. The logistics operator
  # records what physically happened; the minimum a mission carries is a
  # planning decision argued with the ONG team, and the dashboard raises alarms
  # off it. The auditor is the mirror image — reads everything, changes nothing.
  defp may_plan?(scope) do
    Scope.effective_role(scope) in User.roles_that_plan()
  end

  defp plan_block(scope) do
    if may_plan?(scope) do
      EstoqueOSWeb.UserAuth.write_block(scope)
    else
      gettext("Only a manager changes the minimum.")
    end
  end

  defp id_of(%{product: %{id: id}}), do: id

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/stock"} back_label={gettext("Stock")}>
        {@history.product.name}
        <:subtitle>
          {gettext("Counted in %{unit}", unit: @history.product.stock_unit)}
          <span :if={@history.product.sector}>· {@history.product.sector}</span>
          <.status :if={@history.product.controlled} kind={:controlled} class="ml-1" />
          <span :if={not @history.product.expiry_expected} class="badge badge-ghost badge-sm ml-1">
            {gettext("no expiry expected")}
          </span>
          <span :if={not @history.product.lot_expected} class="badge badge-ghost badge-sm ml-1">
            {gettext("no lot expected")}
          </span>
        </:subtitle>
        <!-- The screen that answers "how much of this is left" is the screen
             somebody is standing on when they decide to take some out. Sending
             them to the menu, then to a search field, to type the name of the
             product whose page they were already reading, is three steps to
             arrive where they started. The product travels in the link and
             comes out picked.

             Only for whoever may actually write the movement off — the same
             table the menu reads, so this shortcut and the menu can never
             disagree about who is allowed through. -->
        <:actions>
          <.button
            :if={Layouts.may_access?(@current_scope, ~p"/issue")}
            navigate={~p"/issue?product=#{@history.product.id}"}
            variant="primary"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" />
            {gettext("Write off")}
          </.button>
        </:actions>
      </.header>

      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mt-6">
        <.stat label={gettext("On hand")} value={quantity(on_hand(@history))} dense />
        <.stat label={gettext("Stored lots")} value={length(@history.positions)} dense />
        <!-- The one figure on this screen that is a decision rather than a
             measurement, so it is the one that can be typed into. Everything
             else here is the ledger reporting itself. -->
        <div class="panel px-3 py-2 flex flex-col gap-0.5">
          <p class="eyebrow text-base-content/60">{gettext("Minimum")}</p>
          <form id="minimum-form" phx-submit="set_minimum" class="flex items-center gap-2 mt-1">
            <input
              type="text"
              name="min_stock_override"
              value={quantity(@history.product.min_stock_override)}
              inputmode="decimal"
              data-numeric
              disabled={not may_plan?(@current_scope) or not @writable?}
              title={plan_block(@current_scope)}
              class="input input-sm input-bordered w-24 text-right"
              aria-label={gettext("Minimum a mission is expected to carry")}
            />
            <button
              :if={may_plan?(@current_scope)}
              class="btn btn-sm"
              disabled={not @writable?}
              phx-disable-with={gettext("Saving...")}
            >
              {gettext("Save")}
            </button>
          </form>
          <p class="text-xs opacity-60 mt-1">
            {gettext("what a mission is expected to carry")}
          </p>
        </div>
        <.stat label={gettext("Movements")} value={@history.movement_count} dense />

        <!-- The answer to "it came in on three invoices at three prices, what is
             it worth". Weighted by what is still on the shelf, and it never goes
             near the ledger: the entries keep the price they entered at.

             The hint is not decoration. Donations are left out of the average
             rather than counted as zero, so a figure covering half the stock has
             to say so, or it gets quoted as though it covered all of it. -->
        <.stat
          :if={@sees_money? and @cost}
          label={gettext("Average unit cost")}
          value={unit_price(@cost.average)}
          money
          dense
          hint={cost_coverage(@cost)}
          tone={if unpriced?(@cost), do: :warn, else: :neutral}
        />
      </div>

      <!-- Small and quiet, and only once there is something to say. The
           question it answers — "who lowered the minimum, and when" — is asked
           after a mission runs short, which is exactly when nobody remembers. -->
      <details :if={@changes != []} class="mt-3 text-sm">
        <summary class="cursor-pointer text-base-content/70">
          {gettext("What was changed here")}
        </summary>
        <ul class="mt-2 space-y-1">
          <li :for={change <- @changes} class="text-base-content/80">
            {gettext("minimum %{from} → %{to}",
              from: change.from_value || gettext("unknown"),
              to: change.to_value || gettext("unknown")
            )} · {datetime(change.inserted_at)}
            <span :if={change.user}>· {change.user.email}</span>
          </li>
        </ul>
      </details>

      <.panel title={gettext("Where it is now")}>
        <.data_table rows={@history.positions} row_id={&"position-#{&1.lot_id}-#{&1.location_id}"}>
          <:empty>
            <.empty
              title={gettext("None of this in stock right now.")}
              note={gettext("Every unit has left. The movements below say where it went.")}
            />
          </:empty>

          <:col :let={row} label={gettext("Lot")} emphasis={:identity}>
            {row.lot_number || gettext("unknown")}
            <.status :if={row.needs_review} kind={:needs_review} />
          </:col>
          <:col :let={row} label={gettext("Expiry")}>{date(row.expires_on)}</:col>
          <:col :let={row} label={gettext("Where")}>{row.location}</:col>
          <:col :let={row} label={gettext("Box")}>
            <.link :if={row.box_id} navigate={~p"/boxes/#{row.box_id}"} class="link link-hover">
              {row.box}
            </.link>
            <.status :if={is_nil(row.box_id)} kind={:unboxed} />
          </:col>
          <:col :let={row} label={gettext("Quantity")} align={:right} emphasis={:primary}>
            {quantity(row.quantity)}
          </:col>

          <!-- `:if` on the slot, not on the cell: a column that only some rows
               would render is a table whose rows have different widths. The
               column appears for whoever handles boxes, and a line that is
               already in one renders the slot empty rather than skipping it.

               Loose stock cannot travel, so the fastest route from "I am
               looking at this product" to "it is in a box" belongs here. The
               box's own screen keeps its list; this is the other door to the
               same act. -->
          <:col
            :let={row}
            :if={@may_box?}
            label={gettext("Into a box")}
            field={:block}
            group
          >
            <.write_gate may={is_nil(row.box_id)} allowed={@writable?} reason={@write_block}>
              <form
                id={"stow-#{row.lot_id}-#{row.location_id}"}
                phx-submit="stow"
                phx-value-lot={row.lot_id}
                phx-value-location={row.location_id}
                class="flex flex-wrap items-center gap-2 justify-end"
              >
                <input
                  type="text"
                  name="box_code"
                  list={"boxes-#{row.location_id}"}
                  placeholder={placeholder_box(@boxes_at[row.location_id])}
                  class="input input-sm input-bordered w-24"
                  aria-label={gettext("Which box at %{location}", location: row.location)}
                />
                <.box_options
                  id={"boxes-#{row.location_id}"}
                  boxes={@boxes_at[row.location_id] || []}
                />

                <!-- The whole line, because putting away half of what is on the
                     floor is the exception. Type less to send part of it. -->
                <input
                  type="text"
                  name="quantity"
                  value={quantity(row.quantity)}
                  inputmode="decimal"
                  data-numeric
                  class="input input-sm input-bordered w-20 text-right"
                  aria-label={gettext("How much to put in")}
                />
                <button class="btn btn-sm" phx-disable-with={gettext("Storing...")}>
                  {gettext("Put away")}
                </button>
              </form>
            </.write_gate>
          </:col>
        </.data_table>
      </.panel>

      <!-- The panel goes, not just its column: a price history with the prices
           taken out is an invitation to ask what is being kept back. -->
      <.panel
        :if={@sees_money?}
        title={gettext("What was paid")}
        note={gettext("Per unit, newest first. A donation is absent rather than shown as free.")}
      >
        <.data_table rows={@history.costs} row_id={&"cost-#{&1.entry.id}"}>
          <:empty>
            <.empty
              title={gettext("No purchase with a value on record.")}
              note={
                gettext(
                  "This product has only ever arrived by donation, or without a price on the document."
                )
              }
            />
          </:empty>

          <:col :let={row} label={gettext("When")} emphasis={:identity}>
            {date(row.occurred_at)}
          </:col>
          <:col :let={row} label={gettext("Supplier")}>
            {supplier_name(row.transaction)}
          </:col>
          <:col :let={row} label={gettext("Lot")}>{row.lot_number || gettext("unknown")}</:col>
          <:col :let={row} label={gettext("Quantity")} align={:right}>
            {quantity(row.quantity)}
          </:col>
          <:col :let={row} label={gettext("Unit price")} align={:right} emphasis={:primary}>
            <.amount value={unit_price(row.unit_cost)} />
          </:col>
        </.data_table>
      </.panel>

      <.panel
        title={gettext("Everything that moved it")}
        note={
          if @history.movement_count > length(@history.movements),
            do:
              gettext("Showing the %{shown} most recent of %{total}.",
                shown: length(@history.movements),
                total: @history.movement_count
              ),
            else: gettext("Newest first.")
        }
      >
        <.data_table rows={@history.movements} row_id={&"movement-#{&1.id}"}>
          <:empty>
            <.empty
              title={gettext("This product has never moved.")}
              note={gettext("It exists in the catalog, but nothing has come in or gone out yet.")}
            />
          </:empty>

          <:col :let={entry} label={gettext("When")} emphasis={:identity}>
            {datetime(entry.transaction.occurred_at)}
          </:col>
          <:col :let={entry} label={gettext("What")}>
            <Movement.movement_badge type={entry.transaction.type} />
            <span :if={entry.transaction.reason_code} class="text-xs opacity-70">
              {Movement.reason_label(entry.transaction.reason_code)}
            </span>
          </:col>
          <:col :let={entry} label={gettext("Lot")}>
            {entry.lot.lot_number || gettext("unknown")}
          </:col>
          <:col :let={entry} label={gettext("Where")}>
            {entry.location.name}
            <span :if={entry.box} class="text-xs opacity-70">· {entry.box.code}</span>
          </:col>
          <:col :let={entry} label={gettext("Mission")}>
            <.link
              :if={entry.transaction.mission}
              navigate={~p"/missions/#{entry.transaction.mission.id}"}
              class="link link-hover"
            >
              {entry.transaction.mission.name}
            </.link>
          </:col>
          <:col :let={entry} label={gettext("Who")}>{who(entry.transaction)}</:col>
          <:col :let={entry} label={gettext("Quantity")} align={:right} emphasis={:primary}>
            <span class={movement_class(entry.quantity)}>{signed(entry.quantity)}</span>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp unpriced?(%{unpriced_quantity: unpriced}), do: Decimal.compare(unpriced, 0) == :gt

  # What the average actually covers. An average is a claim about a quantity,
  # and quoting it without saying which quantity is how a stock value ends up
  # describing a third of the shelf.
  defp cost_coverage(%{average: nil, unpriced_quantity: unpriced}) do
    gettext("no value informed for any of the %{quantity} on hand",
      quantity: quantity(unpriced)
    )
  end

  defp cost_coverage(%{unpriced_quantity: unpriced, priced_quantity: priced} = cost) do
    if unpriced?(cost) do
      gettext("covers %{priced} of %{total}; %{unpriced} arrived without a value",
        priced: quantity(priced),
        total: quantity(cost.quantity),
        unpriced: quantity(unpriced)
      )
    else
      gettext("across all %{quantity} on hand", quantity: quantity(priced))
    end
  end

  defp on_hand(%{positions: positions}) do
    Enum.reduce(positions, Decimal.new(0), &Decimal.add(&2, &1.quantity))
  end

  defp supplier_name(%{invoice: %{supplier: %{trade_name: name}}}) when is_binary(name), do: name
  defp supplier_name(%{invoice: %{supplier: %{legal_name: name}}}) when is_binary(name), do: name
  defp supplier_name(_transaction), do: "—"

  defp who(%{user: %{email: email}}), do: email
  defp who(_transaction), do: "—"

  # The sign is the fastest way to read a ledger line: it says arrival or
  # departure without decoding the movement type first.
  defp signed(%Decimal{} = value) do
    if Decimal.compare(value, 0) == :gt, do: "+" <> quantity(value), else: quantity(value)
  end

  defp movement_class(%Decimal{} = value) do
    if Decimal.compare(value, 0) == :gt, do: "text-success", else: "text-error"
  end

  @impl true
  # Two gates, and they are separate questions. `@writable?` is whether this
  # session may act at all — an admin borrowing a role may not. `may_plan?` is
  # whether this role plans, which the logistics operator does not. The markup
  # disables the field either way; this is the half that cannot be bypassed by
  # a socket message.
  # The same act as the one on the box's screen, reached from the other side.
  # The location is the line's own: a lot loose in two warehouses has two lines
  # and each one puts its stock into a box standing where that stock is.
  def handle_event("stow", %{"lot" => lot_id, "location" => location_id} = params, socket) do
    if socket.assigns.may_box? and socket.assigns.writable? do
      stow(socket, lot_id, to_id(location_id), params)
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_minimum", %{"min_stock_override" => value}, socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.writable? and may_plan?(scope) do
      save_minimum(socket, value, scope)
    else
      {:noreply, put_flash(socket, :error, gettext("You don't have permission to do that."))}
    end
  end

  defp save_minimum(socket, value, scope) do
    product = socket.assigns.history.product

    case Catalog.set_min_stock(product, value, user_id: scope.user.id) do
      {:ok, _updated} ->
        history = ProductHistory.for_product(product.id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Minimum saved."))
         |> assign(:history, history)
         |> assign(:changes, Catalog.product_changes(product.id))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Type the minimum as a number."))}
    end
  end
end
