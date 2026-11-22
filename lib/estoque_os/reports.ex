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

  Empty positions are left out (ledger history, not stock). The unit cost is
  the average actually paid for the lot, nil for donations.
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
      box_id: b.id,
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
      # Always booleans: a nil reaches the template as `nil and ...`, which raises.
      |> Map.put(:expired, !is_nil(row.expires_on) and Date.before?(row.expires_on, today))
      |> Map.put(
        :expiring,
        !is_nil(row.expires_on) and Date.compare(row.expires_on, horizon) != :gt
      )
      # "Running low" is about the *product* across the whole warehouse, not this
      # position, so a filtered or paged view cannot make it look short.
      |> Map.put(:below_minimum, below_minimum?(row, totals))
    end)
    |> sort_rows(opts[:sort])
  end

  @doc """
  One page of stock, with totals so the screen is honest about what it hides.

  Rows are assembled in Elixir (average cost and packaging are not columns), so
  the page is cut afterwards, bounding the LiveView diff. `max_rows` caps the
  query itself, and the screen says when the cap was hit.
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

  # Sorted after assembly: cost and total are computed in Elixir, and SQL would
  # duplicate the costing rule.
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

  # nil sorts last both ways: no expiry is not "oldest", no value is not "cheapest".
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
    # One box searches product, lot label, box code, scanned code and NF number.
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

  # "Which of this delivery is still here?": reached through the `purchase_in`
  # transaction that carries the invoice. Exact, since `ilike "%7%"` on an NF
  # number would match half the warehouse.
  defp invoiced_lots(number) do
    TransactionEntry
    |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
    |> join(:inner, [e, t], i in Invoice, on: i.id == t.invoice_id)
    |> where([e, t, i], i.number == ^number)
    |> select([e], e.lot_id)
  end

  # Arrives from the scope, not the page, so a socket event cannot ask for
  # another segment's stock.
  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, ""), do: query
  defp maybe_segment(query, segment), do: where(query, [_s, _l, p], p.segment == ^segment)

  # The situations are a *union* ("either"), as someone chasing problems reads
  # them; separate `where`s would mean "both at once".
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

  # Product-wide, so it cannot compare inside the row's `where`: products are
  # worked out first and the filter is a membership test.
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

  # The old one-flag-at-a-time spelling.
  defp situations_from_legacy(opts) do
    [
      opts[:only_expiring] && "expiring",
      opts[:only_controlled] && "controlled",
      opts[:only_needs_review] && "review"
    ]
    |> Enum.filter(&is_binary/1)
  end

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

  # "1 CX = 50 UN" as confirmed on import; a product may have several packagings.
  defp packagings_by_product do
    UnitConversion
    |> order_by([c], asc: c.from_unit)
    |> select([c], {c.product_id, %{unit: c.from_unit, factor: c.factor}})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  # One place or several (e.g. warehouse *and* transit).
  defp maybe_filter_locations(query, nil), do: query
  defp maybe_filter_locations(query, []), do: query

  defp maybe_filter_locations(query, ids) when is_list(ids),
    do: where(query, [s], s.location_id in ^ids)

  defp maybe_filter_locations(query, id), do: where(query, [s], s.location_id == ^id)

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

  The spreadsheet states what is physically there; the *difference* is posted
  as a single `inventory_import` transaction, never as a balance. Validation is
  all-or-nothing: a typo posts nothing and reports every bad line, as a
  half-applied count is worse than none.

  With `create_missing: true` (the initial migration), unknown products,
  locations and boxes are created instead of refused, and a box-only row
  registers an empty box. Without it (the recurring count), an unknown product
  is a typo to catch.
  """
  def import_stock(binary, opts \\ []) do
    with {:ok, rows} <- StockWorkbook.import_rows(binary),
         {:ok, resolved} <- resolve_rows(rows, opts) do
      post_counted_rows(resolved, opts)
    end
  end

  defp resolve_rows(rows, opts) do
    {resolved, errors} =
      rows
      |> Enum.reject(&blank_row?/1)
      |> Enum.map(&resolve_row(&1, opts))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    if errors == [] do
      {:ok, Enum.map(resolved, fn {:ok, row} -> row end)}
    else
      {:error, Enum.map(errors, fn {:error, error} -> error end)}
    end
  end

  defp create_missing?(opts), do: Keyword.get(opts, :create_missing, false)

  defp blank_row?(row) do
    is_nil(row.product) and is_nil(row.quantity) and is_nil(row.location)
  end

  # A box-only row registers an empty box, so it exists before its contents are written down.
  defp resolve_row(%{product: nil, box: box} = row, opts) when not is_nil(box) do
    if create_missing?(opts) do
      with {:ok, location} <- fetch_location(row, opts),
           {:ok, box} <- fetch_box(row, location) do
        {:ok, Map.merge(row, %{location: location, box: box, quantity: nil})}
      end
    else
      error(row, gettext("the product name is missing"))
    end
  end

  defp resolve_row(row, opts) do
    with {:ok, product} <- fetch_product(row, opts),
         {:ok, location} <- fetch_location(row, opts),
         {:ok, quantity} <- fetch_quantity(row, opts),
         {:ok, box} <- fetch_box(row, location) do
      {:ok, Map.merge(row, %{product: product, location: location, box: box, quantity: quantity})}
    end
  end

  defp fetch_product(row, opts) do
    cond do
      is_nil(row.product) ->
        error(row, gettext("the product name is missing"))

      product = get_by_name(Product, row.product) ->
        {:ok, product}

      create_missing?(opts) ->
        create_missing_product(row)

      true ->
        error(row, gettext("product \"%{name}\" is not in the catalog", name: row.product))
    end
  end

  # Upper-cased so one item in two cases is one product. Always surgical; a
  # marketing item is reclassified by hand.
  defp create_missing_product(row) do
    case %Product{}
         |> Product.changeset(%{
           name: String.upcase(row.product),
           stock_unit: "UN",
           segment: "medical"
         })
         |> Repo.insert() do
      {:ok, product} ->
        {:ok, product}

      {:error, _changeset} ->
        error(row, gettext("product \"%{name}\" could not be created", name: row.product))
    end
  end

  defp fetch_location(row, opts) do
    cond do
      is_nil(row.location) ->
        error(row, gettext("the location is missing"))

      location = get_by_name(Location, row.location) ->
        {:ok, location}

      create_missing?(opts) ->
        create_missing_location(row)

      true ->
        error(row, gettext("location \"%{name}\" does not exist", name: row.location))
    end
  end

  # A count comes from a mission, so an unknown place becomes a mission site.
  defp create_missing_location(row) do
    case %Location{}
         |> Location.changeset(%{name: row.location, kind: "mission_site"})
         |> Repo.insert() do
      {:ok, location} ->
        {:ok, location}

      {:error, _changeset} ->
        error(row, gettext("location \"%{name}\" could not be created", name: row.location))
    end
  end

  defp fetch_quantity(row, opts) do
    cond do
      is_nil(row.quantity) and create_missing?(opts) -> {:ok, nil}
      is_nil(row.quantity) -> error(row, gettext("the quantity is missing"))
      Decimal.negative?(row.quantity) -> error(row, gettext("the quantity is negative"))
      true -> {:ok, row.quantity}
    end
  end

  # Boxes already exist physically; a count is when we learn of them, so an
  # unknown code creates the box.
  defp fetch_box(%{box: nil}, _location), do: {:ok, nil}

  defp fetch_box(row, location) do
    code = String.upcase(row.box)

    case Repo.one(from b in Box, where: fragment("upper(?)", b.code) == ^code) do
      nil ->
        %Box{} |> Box.changeset(%{code: code, location_id: location.id}) |> Repo.insert()

      %Box{location_id: location_id} = box when location_id == location.id ->
        {:ok, box}

      # A box elsewhere cannot take entries here: the stock would count twice
      # (see `Inventory.enter_manually/1`).
      %Box{} = box ->
        error(
          row,
          gettext("box \"%{code}\" is at %{location} — move it before counting it here",
            code: code,
            location: Repo.get!(Location, box.location_id).name
          )
        )
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

    result =
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

    with {:ok, summary} <- result do
      {:ok, Map.put(summary, :boxes_verified, maybe_verify_boxes(rows, opts))}
    end
  end

  # The migration count is a conference: named boxes were physically opened, so
  # they are verified. The recurring count leaves that to the box-count screen.
  defp maybe_verify_boxes(rows, opts) do
    if create_missing?(opts) do
      ids =
        rows |> Enum.map(& &1.box) |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id) |> Enum.uniq()

      now = DateTime.utc_now(:second)

      {count, _} =
        Box
        |> where([b], b.id in ^ids)
        |> Repo.update_all(set: [last_verified_at: now, updated_at: now])

      count
    else
      0
    end
  end

  # Only the difference is posted; a box-only row posts nothing.
  defp count_entry(%{product: nil}), do: nil
  defp count_entry(%{quantity: nil}), do: nil

  defp count_entry(row) do
    lot = ensure_lot(row)

    # With a box, the count is about it; without, about the location's whole lot.
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
          # `lot_expected` separates "nobody read the pack" from "no lot to read".
          needs_review: is_nil(row.lot_number) and row.product.lot_expected
        })
        |> Repo.insert!()

      lot ->
        lot
    end
  end

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

  # Counted through the items, so the marketing overview ignores a gauze
  # delivery; an item with no product has no segment yet and counts only in the
  # whole-operation figure.
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

  # Positional binding: callers differ in shape but all put the product last.
  defp segment_scope(query, nil), do: query
  defp segment_scope(query, segment), do: where(query, [..., p], p.segment == ^segment)

  @doc """
  Stock that expires within the alert window, soonest first.

  A product may override the global window (insulin deserves more warning than
  gauze). `:location_id` narrows to one place, for the end of a mission.
  `limit: nil` returns every row.
  """
  def expiring_soon(opts \\ []) do
    default_days = opts[:days] || Application.get_env(:estoque_os, :expiry_alert_days, 90)
    today = Date.utc_today()
    horizon = Date.add(today, default_days)

    opts
    |> Keyword.take([:segment, :location_id])
    |> stock_rows()
    |> Enum.filter(fn row ->
      row.expires_on &&
        Date.compare(row.expires_on, product_horizon(row, today, horizon)) != :gt
    end)
    |> Enum.sort_by(& &1.expires_on, Date)
    |> take_rows(Keyword.get(opts, :limit, 10))
    |> Enum.map(&Map.put(&1, :days_left, Date.diff(&1.expires_on, today)))
  end

  defp take_rows(rows, nil), do: rows
  defp take_rows(rows, limit), do: Enum.take(rows, limit)

  defp product_horizon(row, today, default_horizon) do
    case row[:expiry_alert_days_override] do
      nil -> default_horizon
      days -> Date.add(today, days)
    end
  end

  @doc """
  Stock on hand whose lot carries no expiry date, for products that should have
  one.

  A NULL `expires_on` is correct on a donated toy but means "nobody read the
  box" on an anesthetic (a Portaria 344 item). `expiry_expected` tells them
  apart so the list is actionable.
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

  Only products that have moved are considered: the seeded catalog gives every
  line a minimum, which would bury the ones that actually ran low.
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

  These are the balances the system *presumes*.
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

  A repeated count that still disagrees means goods leaving unrecorded or an
  untrustworthy count: the manager's problem, not the counter's. The screen
  that took the count flags the adjustment; this is where it surfaces.

  Two screens flag: the box count (`count_diverged_twice`) and the receiving
  conference (`count_diverged_after_recounts`); one list, as the manager's
  question is the same.

  Newest first, unfiltered by date: an unexplained divergence does not become
  acceptable by ageing.
  """
  def counts_needing_review(opts \\ []) do
    entries = from(e in TransactionEntry, order_by: [asc: e.id], preload: [:box, lot: :product])

    Transaction
    |> where([t], not is_nil(t.review_reason) and is_nil(t.review_acknowledged_at))
    |> order_by([t], desc: t.occurred_at, desc: t.id)
    |> limit(^(opts[:limit] || 5))
    # The invoice: for receiving conferences the manager opens the delivery, not a box.
    |> preload([:user, [invoice: :supplier], entries: ^entries])
    |> Repo.all()
    |> Enum.map(fn transaction ->
      %{
        transaction: transaction,
        reason: transaction.review_reason,
        invoice: transaction.invoice,
        box: transaction.entries |> Enum.find_value(&(&1.box && &1.box.code)),
        # The id too, so the overview can link to the box.
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
    # Locations and supplier, so a load-out reads "from where to where".
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

  @doc """
  What was sold in a period: how much left, what it brought in, what it cost.

  A sale is a `manual_out` to the `sale` destination: no second book. Revenue is
  the entry's price (what the buyer paid), cost the lot's average entry cost
  (what the ONG paid). A donated lot has no cost, so `unpriced` counts those
  lines rather than calling them free.
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
      # A sale is negative in the ledger; flipped once here.
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
  What was sold, grouped by where it went out from.

  For marketing stock the place is the event (a mission site, a fair, the
  office counter).

  The place is read from the entry, not the transaction: a transaction has a
  source location only when it travelled, and a sale does not.
  """
  def sales_by_place(from, to, opts \\ []) do
    {from, to} = period(from, to)
    costs = Inventory.average_unit_costs()

    TransactionEntry
    |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> join(:inner, [e, t, l], p in Product, on: p.id == l.product_id)
    # Before the location join: `segment_scope/2` reads the last binding.
    |> segment_scope(opts[:segment])
    |> join(:inner, [e, t, l, p], loc in Location, on: loc.id == e.location_id)
    |> where([e, t], t.type == "manual_out" and t.destination == "sale")
    |> where([e, t], t.occurred_at >= ^from and t.occurred_at <= ^to)
    |> select([e, t, l, p, loc], %{
      location_id: loc.id,
      location: loc.name,
      kind: loc.kind,
      lot_id: l.id,
      quantity: fragment("-(?)", e.quantity),
      sale_unit_price: e.sale_unit_price
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      unit_cost = costs[row.lot_id]

      row
      |> Map.put(:revenue, mult(row.sale_unit_price, row.quantity))
      |> Map.put(:cost, mult(unit_cost, row.quantity))
      |> Map.put(:unpriced, is_nil(unit_cost))
    end)
    |> Enum.group_by(& &1.location_id)
    |> Enum.map(fn {_id, rows} -> merge_place_rows(rows) end)
    |> Enum.sort_by(& &1.revenue, &(Decimal.compare(&1, &2) != :lt))
  end

  defp merge_place_rows([first | _rest] = rows) do
    revenue = sum(rows, & &1.revenue)
    cost = sum(rows, & &1.cost)

    %{
      location_id: first.location_id,
      location: first.location,
      kind: first.kind,
      quantity: sum(rows, & &1.quantity),
      revenue: revenue,
      cost: cost,
      margin: Decimal.sub(revenue, cost),
      unpriced: Enum.count(rows, & &1.unpriced)
    }
  end

  @doc """
  Revenue, cost and margin, plus `unpriced`, which says how far to trust the margin.
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

  For whoever looks after marketing material ("what do I have made next"),
  three readings of one pass over the sales rows:

    * `best_sellers` — what left most, in units (each shirt size is its own
      product, so this also says which size sells)
    * `cover` — days the shelf lasts at the period's pace, to say when to order
    * `idle` — on the shelf and not sold once; what not to print again

  `idle` only counts what is actually on the shelf.
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

  # Rounded down: eleven and a half days of shelf is eleven.
  defp days_of_cover(row, sale, days) do
    per_day = Decimal.div(sale.quantity, days)

    Map.merge(row, %{
      sold: sale.quantity,
      days:
        row.quantity |> Decimal.div(per_day) |> Decimal.round(0, :floor) |> Decimal.to_integer()
    })
  end

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
      # No cost (usually a donation): counted, not zero, which would make the whole sale margin.
      unpriced: Enum.count(rows, &is_nil(&1.unit_cost))
    }
  end

  defp mult(nil, _quantity), do: Decimal.new(0)
  defp mult(price, quantity), do: Decimal.mult(price, quantity)

  defp sum(rows, fun) do
    rows |> Enum.map(fun) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @doc """
  Movements in a period, grouped by type, adjustments included: an auditor's
  first question is "what happened here".
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
    |> maybe_paperless(opts[:without_invoice])
    |> maybe_to_destination(opts[:destination])
    |> order_by([t], desc: t.occurred_at, desc: t.id)
    |> limit(^(opts[:limit] || 500))
    |> preload([:user, :source_location, :destination_location, invoice: :supplier])
    |> Repo.all()
    |> Repo.preload(
      entries:
        from(e in TransactionEntry,
          order_by: [asc: e.id],
          preload: [:location, lot: :product]
        )
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

  # A movement has no segment; its *entries* do. It counts for a segment when it
  # moved any of its goods, so a mixed movement stays visible to both.
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
  defp maybe_of_type(query, types) when is_list(types), do: where(query, [t], t.type in ^types)
  defp maybe_of_type(query, type), do: where(query, [t], t.type == ^type)

  # Manual entries share `purchase_in`/`donation_in` with invoices; what
  # separates them is the missing document.
  defp maybe_paperless(query, true), do: where(query, [t], is_nil(t.invoice_id))
  defp maybe_paperless(query, _), do: query

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

  What an auditor reads first: stock that changed without goods moving, and the
  reason a human gave.
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

  Portaria 344 items ride in this stock; an auditor wants them listed apart.
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
