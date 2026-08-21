defmodule EstoqueOS.Reports do
  @moduledoc """
  Reading stock out of the ledger for humans, and reading a counted
  spreadsheet back in: the escape hatch whenever connectivity fails in a
  mission.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query

  alias EstoqueOS.Catalog.{Product, ProductGroup, ProductIdentifier, UnitConversion}
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Box, Location, Lot, StockSnapshot, Transaction, TransactionEntry}
  alias EstoqueOS.Invoices.{Invoice, InvoiceItem}
  alias EstoqueOS.Repo
  alias EstoqueOS.Reports.StockWorkbook

  @doc """
  Current stock, one row per product + lot + box + location.

  Empty positions are left out: they are ledger history, not stock. The unit
  cost is the average of what we actually paid for that lot; it stays nil for
  donations, where no value was ever informed.
  """
  def stock_rows(opts \\ []) do
    costs = Inventory.average_unit_costs()
    packagings = packagings_by_product()
    totals = totals_by_product()
    today = Date.utc_today()

    horizon =
      Date.add(
        today,
        opts[:expiry_days] || Application.get_env(:estoque_os, :expiry_alert_days, 90)
      )

    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> join(:left, [s, l, p], g in ProductGroup, on: g.id == p.product_group_id)
    |> join(:left, [s], b in Box, on: b.id == s.box_id)
    |> join(:inner, [s], loc in Location, on: loc.id == s.location_id)
    |> where([s], s.quantity != 0)
    |> maybe_filter_locations(opts[:location_ids] || opts[:location_id])
    |> maybe_segment(opts[:segment])
    |> maybe_search(opts[:search])
    |> filter_situations(
      opts[:situations] || situations_from_legacy(opts),
      horizon,
      today,
      totals
    )
    |> order_by([s, l, p, g, b, loc], asc: p.name, asc_nulls_last: l.expires_on)
    |> maybe_limit(opts[:limit])
    |> select([s, l, p, g, b, loc], %{
      product_id: p.id,
      product: p.name,
      group: g.name,
      controlled: p.controlled,
      lot_expected: p.lot_expected,
      product_stock_unit: p.stock_unit,
      min_stock_override: p.min_stock_override,
      expiry_alert_days_override: p.expiry_alert_days_override,
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      box: b.code,
      box_verified_at: b.last_verified_at,
      location: loc.name,
      location_id: loc.id,
      quantity: s.quantity
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      unit_cost = costs[row.lot_id]

      row
      |> Map.put(:unit_cost, unit_cost)
      |> Map.put(:total, unit_cost && Decimal.mult(unit_cost, row.quantity))
      |> Map.put(:packagings, Map.get(packagings, row.product_id, []))
      # Always booleans: a lot with no expiry is not "maybe expiring", and a nil
      # here reaches the template as `nil and ...`, which raises.
      |> Map.put(:expired, !is_nil(row.expires_on) and Date.before?(row.expires_on, today))
      |> Map.put(
        :expiring,
        !is_nil(row.expires_on) and Date.compare(row.expires_on, horizon) != :gt
      )
      # "Running low" is a fact about the *product*, not about this position: a
      # lot of four in one box is not low if there are two hundred in the next
      # one. The total is the whole warehouse, taken in one query, so a filtered
      # or paginated view cannot make a product look short by hiding the rest of
      # it.
      |> Map.put(:below_minimum, below_minimum?(row, totals))
    end)
    |> sort_rows(opts[:sort])
  end

  @doc """
  One page of stock, with the totals the screen needs to be honest about what
  it is not showing.

  The rows are assembled in Elixir — average cost and packaging are not columns
  — so the page is cut after assembly. That bounds what a LiveView diff has to
  carry, which was the failure that mattered: every lot × box × location in one
  render. It does not bound the query itself, so `max_rows` caps that too and
  the screen says when the cap was hit rather than quietly showing a slice.
  """
  def stock_page(opts \\ []) do
    page = max(opts[:page] || 1, 1)
    per_page = opts[:per_page] || 50
    max_rows = opts[:max_rows] || 5_000

    rows = stock_rows(Keyword.put(opts, :limit, max_rows + 1))
    capped? = length(rows) > max_rows
    rows = Enum.take(rows, max_rows)

    total = length(rows)
    pages = max(ceil(total / per_page), 1)
    page = min(page, pages)

    %{
      rows: Enum.slice(rows, (page - 1) * per_page, per_page),
      page: page,
      pages: pages,
      total: total,
      capped: capped?,
      max_rows: max_rows
    }
  end

  # Sorting happens after the rows are assembled because unit cost and total
  # are computed in Elixir, not in the query — sorting by value in SQL would
  # have to duplicate the costing rule.
  defp sort_rows(rows, nil), do: rows

  defp sort_rows(rows, %{key: key, dir: dir}) do
    Enum.sort_by(rows, &sort_key(&1, key), sorter(dir))
  end

  defp sort_key(row, "product"), do: String.downcase(row.product || "")
  defp sort_key(row, "lot"), do: String.downcase(row.lot_number || "")
  defp sort_key(row, "box"), do: String.downcase(row.box || "")
  defp sort_key(row, "location"), do: String.downcase(row.location || "")
  defp sort_key(row, "expires_on"), do: row.expires_on
  defp sort_key(row, "quantity"), do: row.quantity
  defp sort_key(row, "unit_cost"), do: row.unit_cost
  defp sort_key(row, "total"), do: row.total
  defp sort_key(_row, _key), do: nil

  # nil sorts last in both directions: a lot with no expiry is not "the oldest",
  # and a donation with no value is not "the cheapest".
  defp sorter(dir) do
    fn
      nil, nil -> true
      nil, _b -> false
      _a, nil -> true
      a, b when is_struct(a, Decimal) -> Decimal.compare(a, b) != invert(dir)
      a, b when is_struct(a, Date) -> Date.compare(a, b) != invert(dir)
      a, b when dir == :asc -> a <= b
      a, b -> a >= b
    end
  end

  defp invert(:asc), do: :gt
  defp invert(:desc), do: :lt

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    # One box searches everything a person would type: the product, the lot on
    # the label, or the box code painted on the side.
    trimmed = String.trim(search)
    term = "%#{trimmed}%"

    coded =
      ProductIdentifier
      |> where([i], i.value == ^trimmed)
      |> select([i], i.product_id)

    where(
      query,
      [s, l, p, _g, b],
      ilike(p.name, ^term) or ilike(l.lot_number, ^term) or ilike(b.code, ^term) or
        p.id in subquery(coded) or l.id in subquery(invoiced_lots(trimmed))
    )
  end

  # "Which of this delivery is still here?" — asked with the DANFE in hand, so
  # the number typed is the one printed on the paper. The invoice is not a
  # column on a stock position: a lot arrived on a `purchase_in` and that
  # transaction carries the invoice, so the search reaches it through the
  # ledger. Exact rather than partial, because an NF number is a whole number
  # somebody reads off a document, and `ilike "%7%"` would match half the
  # warehouse.
  defp invoiced_lots(number) do
    TransactionEntry
    |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
    |> join(:inner, [e, t], i in Invoice, on: i.id == t.invoice_id)
    |> where([e, t, i], i.number == ^number)
    |> select([e], e.lot_id)
  end

  # The marketing role's whole view is this line. It arrives from the scope, not
  # from the page, so a filter nobody rendered a control for still holds: an
  # event over the socket cannot ask for a segment the role was never given.
  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, ""), do: query
  defp maybe_segment(query, segment), do: where(query, [_s, _l, p], p.segment == ^segment)

  # One list instead of three flags, and the list is a *union*: asking for
  # expired and below-minimum together means "show me either", which is how
  # somebody chasing problems reads it. Three separate `where`s would have meant
  # "both at once" and answered almost nothing.
  defp filter_situations(query, [], _horizon, _today, _totals), do: query

  defp filter_situations(query, situations, horizon, today, totals) do
    low = below_minimum_ids(totals)

    Enum.reduce(situations, nil, fn situation, acc ->
      condition = situation_condition(situation, horizon, today, low)
      if acc, do: dynamic([s, l, p], ^acc or ^condition), else: condition
    end)
    |> case do
      nil -> query
      condition -> where(query, ^condition)
    end
  end

  defp situation_condition("expired", _horizon, today, _low) do
    dynamic([_s, l], not is_nil(l.expires_on) and l.expires_on < ^today)
  end

  defp situation_condition("expiring", horizon, _today, _low) do
    dynamic([_s, l], not is_nil(l.expires_on) and l.expires_on <= ^horizon)
  end

  defp situation_condition("controlled", _horizon, _today, _low) do
    dynamic([_s, _l, p], p.controlled)
  end

  defp situation_condition("review", _horizon, _today, _low) do
    dynamic([_s, l], l.needs_review and is_nil(l.review_acknowledged_at))
  end

  # "Running low" is a fact about the product across the whole warehouse, not
  # about this position, so it cannot be a comparison inside the row's own
  # `where`. The products are worked out first and the filter is a membership
  # test — the same reasoning `below_minimum?/2` already uses to decide the flag.
  defp situation_condition("below_minimum", _horizon, _today, low) do
    dynamic([_s, l], l.product_id in ^low)
  end

  defp situation_condition(_unknown, _horizon, _today, _low), do: dynamic([_s], false)

  defp below_minimum_ids(totals) do
    Product
    |> where([p], p.active and not is_nil(p.min_stock_override))
    |> select([p], {p.id, p.min_stock_override})
    |> Repo.all()
    |> Enum.filter(fn {id, minimum} ->
      Decimal.compare(Map.get(totals, id, Decimal.new(0)), minimum) == :lt
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # The old spelling, for callers that still pass one flag at a time.
  defp situations_from_legacy(opts) do
    [
      opts[:only_expiring] && "expiring",
      opts[:only_controlled] && "controlled",
      opts[:only_needs_review] && "review"
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Goods that arrived with no lot number or no expiry — usually a donation, or
  # an invoice whose `rastro` group the supplier left out. The overview counts
  # them; this is where the count leads, because a warning that only states a
  # number leaves the manager to find the rows by hand.
  defp below_minimum?(%{min_stock_override: nil}, _totals), do: false

  defp below_minimum?(row, totals) do
    total = Map.get(totals, row.product_id, Decimal.new(0))
    Decimal.compare(total, row.min_stock_override) == :lt
  end

  defp totals_by_product do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> group_by([s, l], l.product_id)
    |> select([s, l], {l.product_id, sum(s.quantity)})
    |> Repo.all()
    |> Map.new()
  end

  # "1 CX = 50 UN" as the team confirmed it on import; a product may have more
  # than one supplier packaging.
  defp packagings_by_product do
    UnitConversion
    |> order_by([c], asc: c.from_unit)
    |> select([c], {c.product_id, %{unit: c.from_unit, factor: c.factor}})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  # One place or several. "What is in the warehouse *and* in transit" was two
  # searches and a subtraction done in somebody's head while the goods were on
  # a truck.
  defp maybe_filter_locations(query, nil), do: query
  defp maybe_filter_locations(query, []), do: query

  defp maybe_filter_locations(query, ids) when is_list(ids),
    do: where(query, [s], s.location_id in ^ids)

  defp maybe_filter_locations(query, id), do: where(query, [s], s.location_id == ^id)

  # Average of the costs stock actually entered at, weighted by quantity.
  # Entries without a cost (donations) are ignored rather than counted as zero.

  @doc """
  Exports the current stock as an XLSX binary.
  """
  def export_stock(opts \\ []) do
    opts
    |> Keyword.take([:location_id, :segment, :search, :only_expiring, :only_controlled])
    |> stock_rows()
    |> StockWorkbook.to_xlsx(money: Keyword.get(opts, :money, true))
  end

  @doc """
  Imports a counted stock spreadsheet.

  The spreadsheet states what is physically there; we post the *difference*
  against the ledger as a single `inventory_import` transaction. Nothing is
  ever written as a balance, so the count remains auditable line by line.

  Validation is all-or-nothing: a spreadsheet with a typo posts nothing and
  reports every bad line, because a half-applied count is worse than no count.
  """
  def import_stock(binary, opts \\ []) do
    with {:ok, rows} <- StockWorkbook.import_rows(binary),
         {:ok, resolved} <- resolve_rows(rows) do
      post_counted_rows(resolved, opts)
    end
  end

  defp resolve_rows(rows) do
    {resolved, errors} =
      rows
      |> Enum.reject(&blank_row?/1)
      |> Enum.map(&resolve_row/1)
      |> Enum.split_with(&match?({:ok, _row}, &1))

    if errors == [] do
      {:ok, Enum.map(resolved, fn {:ok, row} -> row end)}
    else
      {:error, Enum.map(errors, fn {:error, error} -> error end)}
    end
  end

  defp blank_row?(row) do
    is_nil(row.product) and is_nil(row.quantity) and is_nil(row.location)
  end

  defp resolve_row(row) do
    with {:ok, product} <- fetch_product(row),
         {:ok, location} <- fetch_location(row),
         {:ok, quantity} <- fetch_quantity(row),
         {:ok, box} <- fetch_box(row, location) do
      {:ok, Map.merge(row, %{product: product, location: location, box: box, quantity: quantity})}
    end
  end

  defp fetch_product(row) do
    cond do
      is_nil(row.product) ->
        error(row, gettext("the product name is missing"))

      product = get_by_name(Product, row.product) ->
        {:ok, product}

      true ->
        error(row, gettext("product \"%{name}\" is not in the catalog", name: row.product))
    end
  end

  defp fetch_location(row) do
    cond do
      is_nil(row.location) ->
        error(row, gettext("the location is missing"))

      location = get_by_name(Location, row.location) ->
        {:ok, location}

      true ->
        error(row, gettext("location \"%{name}\" does not exist", name: row.location))
    end
  end

  defp fetch_quantity(row) do
    cond do
      is_nil(row.quantity) -> error(row, gettext("the quantity is missing"))
      Decimal.negative?(row.quantity) -> error(row, gettext("the quantity is negative"))
      true -> {:ok, row.quantity}
    end
  end

  # Boxes are physical labels that already exist in the warehouse; a count is
  # exactly when we learn about them, so an unknown code creates the box.
  defp fetch_box(%{box: nil}, _location), do: {:ok, nil}

  defp fetch_box(row, location) do
    code = String.upcase(row.box)

    case Repo.one(from b in Box, where: fragment("upper(?)", b.code) == ^code) do
      nil -> %Box{} |> Box.changeset(%{code: code, location_id: location.id}) |> Repo.insert()
      box -> {:ok, box}
    end
  end

  defp get_by_name(schema, name) do
    Repo.one(from s in schema, where: fragment("lower(?)", s.name) == ^String.downcase(name))
  end

  defp error(row, message), do: {:error, %{line: row.line, message: message}}

  defp post_counted_rows(rows, opts) do
    entries =
      rows
      |> Enum.map(&count_entry/1)
      |> Enum.reject(&is_nil/1)

    if entries == [] do
      {:ok, %{transaction: nil, counted: length(rows), adjusted: 0}}
    else
      case Inventory.post_transaction(%{
             type: "inventory_import",
             user_id: opts[:user_id],
             notes: opts[:notes] || gettext("Stock imported from a spreadsheet"),
             entries: entries
           }) do
        {:ok, transaction} ->
          {:ok, %{transaction: transaction, counted: length(rows), adjusted: length(entries)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The spreadsheet says what is there; the ledger says what we thought was
  # there. Only the difference is posted.
  defp count_entry(row) do
    lot = ensure_lot(row)

    # With a box, the count is about that box; without one, it is about
    # everything the location holds of that lot.
    filters = [lot_id: lot.id, location_id: row.location.id]
    filters = if row.box, do: Keyword.put(filters, :box_id, row.box.id), else: filters

    difference = Decimal.sub(row.quantity, Inventory.balance(filters))

    if Decimal.equal?(difference, 0) do
      nil
    else
      %{
        lot_id: lot.id,
        location_id: row.location.id,
        box_id: row.box && row.box.id,
        quantity: difference,
        unit_cost: row.unit_cost
      }
    end
  end

  defp ensure_lot(row) do
    case Repo.get_by(Lot, product_id: row.product.id, lot_number: row.lot_number) do
      nil ->
        %Lot{}
        |> Lot.changeset(%{
          product_id: row.product.id,
          lot_number: row.lot_number,
          expires_on: row.expires_on,
          # Blank because nobody read the pack, or blank because this product
          # has no lot to read — `lot_expected` is the difference, and the
          # review list is only useful while it holds the first kind.
          needs_review: is_nil(row.lot_number) and row.product.lot_expected
        })
        |> Repo.insert!()

      lot ->
        lot
    end
  end

  ## Dashboard

  @doc """
  Headline numbers for the dashboard.
  """
  def summary(opts \\ []) do
    rows = stock_rows(opts)
    segment = opts[:segment]

    %{
      products:
        Repo.aggregate(from(p in Product, where: p.active) |> segment_scope(segment), :count),
      positions: length(rows),
      units: rows |> Enum.map(& &1.quantity) |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
      known_value:
        rows
        |> Enum.map(& &1.total)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
      invoices_pending: pending_invoices(segment),
      lots_needing_review:
        Repo.aggregate(
          from(l in Lot,
            join: p in Product,
            on: p.id == l.product_id,
            where: l.needs_review and is_nil(l.review_acknowledged_at)
          )
          |> segment_scope(segment),
          :count
        )
    }
  end

  # A note belongs to whichever stock its items land in, and a note can carry
  # both. Counted through the items so the marketing overview does not raise a
  # number about a delivery of gauze — an unattended item, still without a
  # product, has no segment yet and stays in the whole-operation count only.
  defp pending_invoices(nil) do
    Repo.aggregate(from(i in Invoice, where: i.status != "posted"), :count)
  end

  defp pending_invoices(segment) do
    Repo.aggregate(
      from(i in Invoice,
        as: :invoice,
        where:
          i.status != "posted" and
            exists(
              from(item in InvoiceItem,
                join: p in Product,
                on: p.id == item.product_id,
                where: parent_as(:invoice).id == item.invoice_id and p.segment == ^segment,
                select: 1
              )
            )
      ),
      :count
    )
  end

  # For the queries that reach `products` under another name than the stock
  # query's `p`. Written as a positional binding rather than a named one
  # because the callers differ in shape and all of them put the product last.
  defp segment_scope(query, nil), do: query
  defp segment_scope(query, segment), do: where(query, [..., p], p.segment == ^segment)

  @doc """
  Stock that expires within the alert window, soonest first.

  A product may override the global window: insulin nobody can replace on a
  mission deserves more warning than gauze.
  """
  def expiring_soon(opts \\ []) do
    default_days = opts[:days] || Application.get_env(:estoque_os, :expiry_alert_days, 90)
    today = Date.utc_today()
    horizon = Date.add(today, default_days)

    opts
    |> Keyword.take([:segment])
    |> stock_rows()
    |> Enum.filter(fn row ->
      row.expires_on &&
        Date.compare(row.expires_on, product_horizon(row, today, horizon)) != :gt
    end)
    |> Enum.sort_by(& &1.expires_on, Date)
    |> Enum.take(opts[:limit] || 10)
    |> Enum.map(&Map.put(&1, :days_left, Date.diff(&1.expires_on, today)))
  end

  defp product_horizon(row, today, default_horizon) do
    case row[:expiry_alert_days_override] do
      nil -> default_horizon
      days -> Date.add(today, days)
    end
  end

  @doc """
  Stock on hand whose lot carries no expiry date, for products that should have
  one.

  A NULL `expires_on` is two different facts. On a donated teddy bear it is
  correct and permanent. On an anesthetic it means nobody read the box — and that
  is a Portaria 344 item travelling with the rest of the stock. `expiry_expected`
  is what tells them apart, so this list is short enough to act on instead of
  being the whole donations shelf.
  """
  def missing_expiry(opts \\ []) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> join(:inner, [s], loc in Location, on: loc.id == s.location_id)
    |> where([s, l, p], s.quantity != 0 and is_nil(l.expires_on) and p.expiry_expected)
    |> segment_scope(opts[:segment])
    |> order_by([s, l, p], desc: p.controlled, asc: p.name)
    |> limit(^(opts[:limit] || 10))
    |> select([s, l, p, loc], %{
      product_id: p.id,
      product: p.name,
      controlled: p.controlled,
      lot_id: l.id,
      lot_number: l.lot_number,
      location: loc.name,
      quantity: s.quantity
    })
    |> Repo.all()
  end

  @doc """
  Products sitting at or below the minimum a mission is expected to carry.

  Only products that have moved at least once are considered. The seeded
  catalog gives every one of its 322 lines a minimum, so listing the untouched
  ones would bury the handful that actually ran low under a full catalog dump.
  """
  def below_minimum(opts \\ []) do
    balances =
      StockSnapshot
      |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
      |> group_by([s, l], l.product_id)
      |> select([s, l], {l.product_id, sum(s.quantity)})
      |> Repo.all()
      |> Map.new()

    moved =
      TransactionEntry
      |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
      |> select([e, l], l.product_id)
      |> distinct(true)
      |> Repo.all()

    Product
    |> where([p], p.active and not is_nil(p.min_stock_override))
    |> where([p], p.id in ^moved)
    |> segment_scope(opts[:segment])
    |> Repo.all()
    |> Enum.map(fn product ->
      quantity = Map.get(balances, product.id, Decimal.new(0))

      %{
        product: product,
        quantity: quantity,
        minimum: product.min_stock_override,
        missing: Decimal.max(Decimal.sub(product.min_stock_override, quantity), Decimal.new(0))
      }
    end)
    |> Enum.filter(&(Decimal.compare(&1.quantity, &1.minimum) == :lt))
    |> Enum.sort_by(& &1.missing, &(Decimal.compare(&1, &2) != :lt))
    |> Enum.take(opts[:limit] || 10)
  end

  @doc """
  Boxes holding stock that nobody has counted for a while.

  These are the balances the system *presumes*; the mini-audit flow will start
  from this list.
  """
  def stale_boxes(opts \\ []) do
    days = opts[:days] || 30
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)

    Box
    |> join(:inner, [b], s in StockSnapshot, on: s.box_id == b.id)
    |> join(:inner, [b], loc in Location, on: loc.id == b.location_id)
    |> where([b, s], s.quantity != 0)
    |> where([b], is_nil(b.last_verified_at) or b.last_verified_at < ^cutoff)
    |> group_by([b, s, loc], [b.id, b.code, b.last_verified_at, loc.name])
    |> order_by([b], asc_nulls_first: b.last_verified_at)
    |> limit(^(opts[:limit] || 10))
    |> select([b, s, loc], %{
      box: b.code,
      location: loc.name,
      last_verified_at: b.last_verified_at,
      quantity: sum(s.quantity)
    })
    |> Repo.all()
  end

  @doc """
  Counts somebody needs to look at.

  A count that was repeated and still disagreed is not a correction anyone
  should file quietly: either goods are leaving without a record, or the count
  cannot be trusted, and both are the manager's problem rather than the
  counter's. The screen that took the count flags the adjustment; this is where
  the flag surfaces.

  Two screens flag: the box count (`count_diverged_twice`) and the receiving
  conference (`count_diverged_after_recounts`). One list, because the question a
  manager is answering is the same either way — somebody counted this more than
  once and we still do not agree with our own records.

  Ordered newest first and deliberately unfiltered by date — an unexplained
  divergence does not become acceptable by ageing.
  """
  def counts_needing_review(opts \\ []) do
    entries = from(e in TransactionEntry, order_by: [asc: e.id], preload: [:box, lot: :product])

    Transaction
    |> where([t], not is_nil(t.review_reason) and is_nil(t.review_acknowledged_at))
    |> order_by([t], desc: t.occurred_at, desc: t.id)
    |> limit(^(opts[:limit] || 5))
    # The invoice comes along because half of these are now receiving
    # conferences rather than box counts, and for those the row the manager
    # wants to open is the delivery, not the box.
    |> preload([:user, [invoice: :supplier], entries: ^entries])
    |> Repo.all()
    |> Enum.map(fn transaction ->
      %{
        transaction: transaction,
        reason: transaction.review_reason,
        invoice: transaction.invoice,
        box: transaction.entries |> Enum.find_value(&(&1.box && &1.box.code)),
        # The id as well as the code: the overview names the box that disagreed
        # and has to be able to lead there. A code alone leaves the manager
        # searching the box list for the row they were just told about.
        box_id: transaction.entries |> Enum.find_value(&(&1.box && &1.box.id)),
        products:
          transaction.entries
          |> Enum.map(& &1.lot.product.name)
          |> Enum.uniq()
      }
    end)
  end

  @doc """
  The last movements, for the "what happened here" panel.
  """
  def recent_activity(opts \\ []) do
    entries = from(e in TransactionEntry, order_by: [asc: e.id], preload: [lot: :product])

    Transaction
    |> maybe_touching_segment(opts[:segment])
    |> order_by([t], desc: t.occurred_at, desc: t.id)
    |> limit(^(opts[:limit] || 8))
    # Locations and supplier come along because the overview says what happened,
    # not just that something did: a load-out is worth "from where to where".
    |> preload([
      :user,
      :source_location,
      :destination_location,
      [invoice: :supplier],
      entries: ^entries
    ])
    |> Repo.all()
    |> Enum.map(fn transaction ->
      %{
        transaction: transaction,
        lines: length(transaction.entries),
        units:
          transaction.entries
          |> Enum.map(& &1.quantity)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      }
    end)
  end

  ## Sales

  @doc """
  What was sold in a period: how much left, what it brought in, what it had
  cost.

  A sale is a `manual_out` to the `sale` destination, so this reads the same
  ledger as everything else — there is no second book. Revenue comes from the
  price on the entry, which is what the buyer paid; cost comes from the average
  the lot entered at, which is what the ONG paid. Margin is the subtraction, and
  it is only as honest as the second number: a line drawn from a donated lot has
  no cost at all, so `unpriced` counts those rather than calling them free.
  """
  def sales(from, to, opts \\ []) do
    {from, to} = period(from, to)
    costs = Inventory.average_unit_costs()

    TransactionEntry
    |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> join(:inner, [e, t, l], p in Product, on: p.id == l.product_id)
    |> where([e, t], t.type == "manual_out" and t.destination == "sale")
    |> where([e, t], t.occurred_at >= ^from and t.occurred_at <= ^to)
    |> segment_scope(opts[:segment])
    |> order_by([e, t, l, p], asc: p.name)
    |> select([e, t, l, p], %{
      product_id: p.id,
      product: p.name,
      unit: p.stock_unit,
      lot_id: l.id,
      # Signed in the ledger, and a sale is negative. Flipped once, here, so
      # every reader below counts upwards.
      quantity: fragment("-(?)", e.quantity),
      sale_unit_price: e.sale_unit_price
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      unit_cost = costs[row.lot_id]

      row
      |> Map.put(:unit_cost, unit_cost)
      |> Map.put(:revenue, mult(row.sale_unit_price, row.quantity))
      |> Map.put(:cost, mult(unit_cost, row.quantity))
    end)
    |> Enum.group_by(& &1.product_id)
    |> Enum.map(fn {_id, rows} -> merge_sale_rows(rows) end)
    |> Enum.sort_by(& &1.revenue, &(Decimal.compare(&1, &2) != :lt))
  end

  @doc """
  The three numbers a sales report is read for, plus the one that says how much
  to trust the third.
  """
  def sales_totals(rows) do
    revenue = sum(rows, & &1.revenue)
    cost = sum(rows, & &1.cost)

    %{
      quantity: sum(rows, & &1.quantity),
      revenue: revenue,
      cost: cost,
      margin: Decimal.sub(revenue, cost),
      unpriced: rows |> Enum.map(& &1.unpriced) |> Enum.sum()
    }
  end

  @doc """
  How the sold stock is moving: what leaves most, what runs out first, and what
  is not leaving at all.

  Written for whoever looks after the marketing material, whose question is not
  "will the mission be short" but "what do I have made next". Three answers out
  of one pass over the same sales rows, because they are three readings of the
  same fact:

    * `best_sellers` — what left most, counted in units rather than in money.
      Each shirt size is its own product, so this list is also the answer to
      which size sells.
    * `cover` — how many days the shelf lasts at the pace of the period. The
      number that says when to order, rather than after it is already zero.
    * `idle` — what is on the shelf and did not sell one unit. What not to have
      printed again.

  Products that never moved at all are not idle stock: something bought and
  never sold once is a different conversation from something that stopped
  selling, and the shelf is what this report is about — so `idle` only counts
  what is actually there.
  """
  def sales_pace(from, to, opts \\ []) do
    rows = sales(from, to, opts)
    sold = Map.new(rows, &{&1.product_id, &1})
    days = max(Date.diff(to, from), 1)
    limit = opts[:limit] || 5

    on_hand =
      opts[:segment]
      |> product_balances()
      |> Enum.reject(&(Decimal.compare(&1.quantity, 0) != :gt))

    %{
      totals: sales_totals(rows),
      days: days,
      best_sellers: rows |> Enum.sort_by(& &1.quantity, &desc/2) |> Enum.take(limit),
      cover:
        on_hand
        |> Enum.filter(&Map.has_key?(sold, &1.product_id))
        |> Enum.map(&days_of_cover(&1, sold[&1.product_id], days))
        |> Enum.sort_by(& &1.days)
        |> Enum.take(limit),
      idle:
        on_hand
        |> Enum.reject(&Map.has_key?(sold, &1.product_id))
        |> Enum.sort_by(& &1.quantity, &desc/2)
        |> Enum.take(limit)
    }
  end

  # Rounded down, because a shelf that lasts eleven and a half days lasts
  # eleven: the half day is the one somebody would have counted on.
  defp days_of_cover(row, sale, days) do
    per_day = Decimal.div(sale.quantity, days)

    Map.merge(row, %{
      sold: sale.quantity,
      days:
        row.quantity |> Decimal.div(per_day) |> Decimal.round(0, :floor) |> Decimal.to_integer()
    })
  end

  # What is on the shelf right now, per product, for one stock. The snapshot
  # table is the maintained cache of the ledger, which is what every other
  # balance on the dashboard reads too.
  defp product_balances(segment) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> where([s, l, p], p.active)
    |> segment_scope(segment)
    |> group_by([s, l, p], [p.id, p.name, p.stock_unit])
    |> select([s, l, p], %{
      product_id: p.id,
      product: p.name,
      unit: p.stock_unit,
      quantity: sum(s.quantity)
    })
    |> Repo.all()
  end

  defp desc(a, b), do: Decimal.compare(a, b) != :lt

  defp merge_sale_rows([first | _rest] = rows) do
    %{
      product_id: first.product_id,
      product: first.product,
      unit: first.unit,
      quantity: sum(rows, & &1.quantity),
      revenue: sum(rows, & &1.revenue),
      cost: sum(rows, & &1.cost),
      # Lines whose lot never carried a cost — a donation, usually. Counted
      # rather than treated as zero, which would report the whole sale as
      # margin.
      unpriced: Enum.count(rows, &is_nil(&1.unit_cost))
    }
  end

  defp mult(nil, _quantity), do: Decimal.new(0)
  defp mult(price, quantity), do: Decimal.mult(price, quantity)

  defp sum(rows, fun) do
    rows |> Enum.map(fun) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  ## Audit trail

  @doc """
  Movements in a period, grouped by type.

  The first thing an auditor asks is "what happened here", and the honest
  answer is a count of every kind of event, including the ones nobody likes to
  show: adjustments.
  """
  def movement_summary(from, to) do
    {from, to} = period(from, to)

    Transaction
    |> join(:inner, [t], e in TransactionEntry, on: e.transaction_id == t.id)
    |> where([t], t.occurred_at >= ^from and t.occurred_at <= ^to)
    |> group_by([t], t.type)
    |> select([t, e], %{
      type: t.type,
      transactions: count(t.id, :distinct),
      lines: count(e.id),
      units_in: sum(fragment("greatest(?, 0)", e.quantity)),
      units_out: sum(fragment("least(?, 0)", e.quantity))
    })
    |> Repo.all()
    |> Enum.sort_by(& &1.type)
  end

  @doc """
  Every movement in a period, newest first — the audit trail itself.
  """
  def transaction_log(from, to, opts \\ []) do
    {from, to} = period(from, to)

    Transaction
    |> where([t], t.occurred_at >= ^from and t.occurred_at <= ^to)
    |> maybe_touching_segment(opts[:segment])
    |> maybe_of_type(opts[:type])
    |> maybe_to_destination(opts[:destination])
    |> order_by([t], desc: t.occurred_at, desc: t.id)
    |> limit(^(opts[:limit] || 500))
    |> preload([:user, :source_location, :destination_location, invoice: :supplier])
    |> Repo.all()
    |> Repo.preload(
      entries: from(e in TransactionEntry, order_by: [asc: e.id], preload: [lot: :product])
    )
    |> Enum.map(fn transaction ->
      %{
        transaction: transaction,
        lines: length(transaction.entries),
        units:
          transaction.entries
          |> Enum.map(& &1.quantity)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
        value: entries_value(transaction.entries)
      }
    end)
  end

  # A movement has no segment of its own — its *entries* do, through the lot's
  # product. A transaction counts as marketing when it moved any marketing
  # goods, which is the only reading that keeps a mixed movement visible to the
  # person it concerns.
  defp maybe_touching_segment(query, nil), do: query
  defp maybe_touching_segment(query, ""), do: query

  defp maybe_touching_segment(query, segment) do
    touching =
      TransactionEntry
      |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
      |> join(:inner, [e, l], p in Product, on: p.id == l.product_id)
      |> where([e, l, p], p.segment == ^segment)
      |> select([e], e.transaction_id)

    where(query, [t], t.id in subquery(touching))
  end

  defp maybe_of_type(query, nil), do: query
  defp maybe_of_type(query, ""), do: query
  defp maybe_of_type(query, type), do: where(query, [t], t.type == ^type)

  # This is the filter the operation asked for by another name: "we need to know
  # which items were donated". Answering it was impossible while the destination
  # lived in free-text notes.
  defp maybe_to_destination(query, nil), do: query
  defp maybe_to_destination(query, ""), do: query

  defp maybe_to_destination(query, destination),
    do: where(query, [t], t.destination == ^destination)

  defp entries_value(entries) do
    Enum.reduce(entries, Decimal.new(0), fn entry, total ->
      case entry.unit_cost do
        nil -> total
        cost -> Decimal.add(total, Decimal.mult(cost, entry.quantity))
      end
    end)
  end

  @doc """
  Adjustments in a period, grouped by reason.

  This is the number an auditor reads first: stock that changed without goods
  moving, and the reason a human gave for it.
  """
  def adjustment_summary(from, to) do
    {from, to} = period(from, to)

    Transaction
    |> join(:inner, [t], e in TransactionEntry, on: e.transaction_id == t.id)
    |> where([t], t.type == "adjustment" and t.occurred_at >= ^from and t.occurred_at <= ^to)
    |> group_by([t], t.reason_code)
    |> select([t, e], %{
      reason_code: t.reason_code,
      transactions: count(t.id, :distinct),
      units_in: sum(fragment("greatest(?, 0)", e.quantity)),
      units_out: sum(fragment("least(?, 0)", e.quantity))
    })
    |> Repo.all()
    |> Enum.sort_by(& &1.reason_code)
  end

  @doc """
  Controlled substances currently in stock, per lot and position.

  Portaria 344 items ride in this stock, and an auditor will want them listed
  separately rather than buried in a 300-line inventory.
  """
  def controlled_stock(opts \\ []) do
    opts |> Keyword.take([:segment]) |> stock_rows() |> Enum.filter(& &1.controlled)
  end

  # A period given as dates covers whole days, inclusive.
  defp period(from, to) do
    {to_start_of_day(from), to_end_of_day(to)}
  end

  defp to_start_of_day(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00])
  defp to_start_of_day(%DateTime{} = datetime), do: datetime
  defp to_start_of_day(nil), do: DateTime.new!(~D[2000-01-01], ~T[00:00:00])

  defp to_end_of_day(%Date{} = date), do: DateTime.new!(date, ~T[23:59:59])
  defp to_end_of_day(%DateTime{} = datetime), do: datetime
  defp to_end_of_day(nil), do: DateTime.utc_now(:second)
end
