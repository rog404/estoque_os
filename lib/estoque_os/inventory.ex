defmodule EstoqueOS.Inventory do
  @moduledoc """
  The stock ledger.

  Stock is an append-only journal: `post_transaction/1` is the only way it ever
  changes. Balances are *derived* by summing `transaction_entries`;
  `stock_snapshots` is a rollup refreshed inside the same database transaction
  and is never consulted as the source of truth — `recalculate_snapshots/0`
  can rebuild it from the ledger at any time, and a test asserts they agree.
  """

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.{Box, Lot, StockSnapshot, Transaction, TransactionEntry}
  alias EstoqueOS.Repo

  # Stock may only go negative through an explicit adjustment, where a human
  # states a reason. Every other movement must be covered by real stock.
  @types_allowed_to_go_negative ~w(adjustment)

  @doc """
  Takes goods into stock that arrived without an invoice.

  Real stock with no document and no price. Posts `donation_in` so reports keep
  what was given apart from `purchase_in`.

  A donation's `unit_cost` is always NULL: a symbolic centavo would drag average
  cost and stock value toward a number nobody paid.

  Quantity is in the product's own stock unit, with no packaging conversion
  (a person holding the goods counts the things).
  """
  def enter_manually(attrs) do
    product_id = to_id(field(attrs, :product_id))
    location_id = to_id(field(attrs, :location_id))
    quantity = to_decimal(field(attrs, :quantity))

    box_id = to_id(field(attrs, :box_id))

    cond do
      is_nil(product_id) -> {:error, :missing_product}
      is_nil(location_id) -> {:error, :missing_location}
      is_nil(quantity) or Decimal.compare(quantity, 0) != :gt -> {:error, :invalid_quantity}
      not box_is_at?(box_id, location_id) -> {:error, :box_elsewhere}
      true -> do_enter_manually(product_id, location_id, quantity, box_id, attrs)
    end
  end

  # Goods at location A inside a box at location B would count twice (by
  # location and by box), and no recount could tell which half is real.
  defp box_is_at?(nil, _location_id), do: true

  defp box_is_at?(box_id, location_id) do
    Repo.exists?(from b in Box, where: b.id == ^box_id and b.location_id == ^location_id)
  end

  defp do_enter_manually(product_id, location_id, quantity, box_id, attrs) do
    {type, unit_cost} = origin(attrs, quantity)

    Multi.new()
    |> Multi.run(:lot, fn _repo, _changes ->
      find_or_create_lot(product_id, attrs)
    end)
    |> Multi.run(:transaction, fn _repo, %{lot: lot} ->
      post_transaction(%{
        type: type,
        user_id: field(attrs, :user_id),
        notes: field(attrs, :notes),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location_id,
            box_id: box_id,
            quantity: quantity,
            unit_cost: unit_cost
          }
        ]
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes.transaction}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # A donation has **no** cost: nil, never zero or a symbolic cent, which
  # poison averages and stock value (SPEC §4.7). Goods bought without an invoice
  # have a real price, given as a unit price or a total (divided by quantity).
  defp origin(attrs, quantity) do
    case field(attrs, :origin) do
      "purchase" -> {"purchase_in", purchase_unit_cost(attrs, quantity)}
      _donation -> {"donation_in", nil}
    end
  end

  defp purchase_unit_cost(attrs, quantity) do
    case {to_decimal(field(attrs, :unit_cost)), to_decimal(field(attrs, :total_cost))} do
      {nil, nil} -> nil
      {nil, total} -> Decimal.div(total, quantity)
      {unit, _total} -> unit
    end
  end

  # An existing lot number for the product is the same lot: two rows would split
  # the balance and hide half of it from a recall.
  defp find_or_create_lot(product_id, attrs) do
    number =
      case field(attrs, :lot_number) do
        value when value in [nil, ""] -> nil
        value -> String.trim(value)
      end

    expires_on = field(attrs, :expires_on)

    existing =
      if number do
        Repo.one(from l in Lot, where: l.product_id == ^product_id and l.lot_number == ^number)
      end

    case existing do
      %Lot{} = lot ->
        join_lot(lot, to_date(expires_on))

      nil ->
        %Lot{}
        |> Lot.changeset(%{
          product_id: product_id,
          lot_number: number,
          expires_on: blank_to_nil(expires_on),
          needs_review: is_nil(number) and lot_expected?(product_id)
        })
        |> Repo.insert()
    end
  end

  # A missing lot number means "nobody read the pack" for gauze but nothing to
  # read for a donated blanket; `products.lot_expected` tells them apart so the
  # review list is not filled with unresolvable items.
  defp lot_expected?(product_id) do
    case Repo.one(from p in Product, where: p.id == ^product_id, select: p.lot_expected) do
      nil -> true
      expected -> expected
    end
  end

  # A new expiry fills a blank on a known lot; one that disagrees with the
  # record is a conflict, as silently picking either risks the wrong batch in a recall.
  defp join_lot(%Lot{} = lot, nil), do: {:ok, lot}
  defp join_lot(%Lot{expires_on: same} = lot, same), do: {:ok, lot}

  defp join_lot(%Lot{expires_on: nil} = lot, %Date{} = expires_on) do
    lot |> Lot.changeset(%{expires_on: expires_on}) |> Repo.update()
  end

  defp join_lot(%Lot{}, %Date{}), do: {:error, :expiry_conflict}

  defp to_date(%Date{} = date), do: date

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp to_date(_value), do: nil

  @doc """
  A manual issue that went to a donation, loaded for its certificate.

  Returns nil for anything else, so a certificate can never be printed for
  goods that went to the operating room.
  """
  def get_donation_issue(id) do
    entries = from(e in TransactionEntry, order_by: [asc: e.id], preload: [lot: :product])

    Transaction
    |> where([t], t.id == ^id and t.type == "manual_out" and t.destination == "donation")
    |> preload([:user, :source_location, entries: ^entries])
    |> Repo.one()
  end

  @doc """
  What an issue took out, in the terms a certificate states.

  `unpriced_lines` is counted, not hidden: donated goods have no cost and a zero
  would understate what was handed over.
  """
  def issue_totals(%Transaction{} = transaction) do
    {value, unpriced} =
      Enum.reduce(transaction.entries, {Decimal.new(0), 0}, fn entry, {total, unpriced} ->
        quantity = Decimal.abs(entry.quantity)

        case entry.unit_cost do
          nil -> {total, unpriced + 1}
          cost -> {Decimal.add(total, Decimal.mult(cost, quantity)), unpriced}
        end
      end)

    %{
      value: value,
      unpriced_lines: unpriced,
      units:
        Enum.reduce(transaction.entries, Decimal.new(0), fn entry, total ->
          Decimal.add(total, Decimal.abs(entry.quantity))
        end)
    }
  end

  @doc """
  Balance per product at a location, for several products at once.

  Products with nothing there are absent from the map, not zero.
  """
  def balances_by_product(product_ids, location_id) when is_list(product_ids) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, l], l.product_id in ^product_ids and e.location_id == ^location_id)
    |> group_by([e, l], l.product_id)
    |> select([e, l], {l.product_id, sum(e.quantity)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Expired stock per product at a location, for several products at once.

  Kit assembly is refused while a component has expired stock here
  (`EstoqueOS.Kits.assemble/3`): a kit is sealed and its contents stop being
  visible. Products with nothing expired are absent.

  `on_date` defaults to today.
  """
  def expired_balances_by_product(product_ids, location_id, on_date \\ nil)
      when is_list(product_ids) do
    on_date = on_date || Date.utc_today()

    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, l], l.product_id in ^product_ids and e.location_id == ^location_id)
    |> where([e, l], not is_nil(l.expires_on) and l.expires_on < ^on_date)
    |> group_by([e, l], l.product_id)
    |> having([e], sum(e.quantity) > 0)
    |> select([e, l], %{
      product_id: l.product_id,
      quantity: sum(e.quantity),
      earliest_expiry: min(l.expires_on)
    })
    |> Repo.all()
    |> Map.new(&{&1.product_id, Map.delete(&1, :product_id)})
  end

  @doc """
  Everything that is actually at a location, product by product, in stock order.

  Built from what is *there*, not from the catalog: a zero row would invite a
  write-off that cannot complete. `> 0`, not `!= 0`: a negative balance is a bug
  or pending correction, nothing anyone can carry away.
  """
  def products_at(location_id, opts \\ []) do
    boxes = boxes_by_product_at(location_id)

    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> join(:inner, [e, l], p in Product, on: p.id == l.product_id)
    |> where([e], e.location_id == ^location_id)
    |> maybe_segment(opts[:segment])
    |> group_by([e, l, p], [p.id, p.name, p.stock_unit, p.controlled])
    |> having([e], sum(e.quantity) > 0)
    |> order_by([e, l, p], asc: p.name)
    |> select([e, l, p], %{
      product_id: p.id,
      product: p.name,
      stock_unit: p.stock_unit,
      controlled: p.controlled,
      quantity: sum(e.quantity)
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :boxes, Map.get(boxes, &1.product_id, [])))
  end

  # Which stock the caller is looking at, passed down from the scope.
  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, ""), do: query
  defp maybe_segment(query, segment), do: where(query, [_e, _l, p], p.segment == ^segment)

  # Where to physically reach each product. A separate query from the product
  # totals: whether a *box* still holds a product is a different grouping.
  defp boxes_by_product_at(location_id) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> join(:inner, [e], b in Box, on: b.id == e.box_id)
    |> where([e], e.location_id == ^location_id)
    |> group_by([e, l, b], [l.product_id, b.code])
    |> having([e], sum(e.quantity) > 0)
    |> order_by([e, l, b], asc: b.code)
    |> select([e, l, b], {l.product_id, b.code})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Appends a transaction and its entries, refreshing the snapshot cache in the
  same database transaction.

  Returns `{:ok, transaction}` with entries loaded, or `{:error, changeset}`.
  Refuses to leave any lot/box/location with a negative balance unless the
  transaction is an adjustment.
  """
  def post_transaction(attrs) do
    changeset = Transaction.changeset(%Transaction{}, attrs)

    Multi.new()
    |> Multi.insert(:transaction, changeset)
    |> Multi.run(:snapshots, &apply_entries_to_snapshots/2)
    |> Multi.run(:balances, &ensure_balances_are_not_negative/2)
    |> Repo.transaction()
    |> case do
      {:ok, %{transaction: transaction}} -> {:ok, Repo.preload(transaction, :entries)}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  What each lot actually cost, averaged over the entries that brought it in and
  weighted by quantity.

  Entries with no cost (donations) are left out, not counted as zero.
  """
  def average_unit_costs do
    TransactionEntry
    |> where([e], e.quantity > 0 and not is_nil(e.unit_cost))
    |> group_by([e], e.lot_id)
    |> select([e], {e.lot_id, sum(fragment("? * ?", e.unit_cost, e.quantity)) / sum(e.quantity)})
    |> Repo.all()
    |> Map.new(fn {lot_id, average} -> {lot_id, Decimal.round(average, 6)} end)
  end

  @doc """
  What one unit of a product is worth right now, and how much of the stock that
  figure actually covers.

  A **weighted moving average** over stock on hand: each lot's average cost
  weighted by the quantity still here. Not FIFO, since picking is FEFO and FIFO
  would describe goods that are not the ones leaving.

  Donated stock has **no** cost (SPEC §4.7): excluded from the average and
  reported as `unpriced_quantity` so the caller can attach the caveat.

  A read-model, never written back to `transaction_entries`, which keep their
  entry price as the auditor's trail.

  `average` is nil when nothing on hand has a known cost; that is not zero.
  """
  def average_cost_by_product(product_ids \\ nil) do
    costs = average_unit_costs()

    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> where([s], s.quantity > 0)
    |> maybe_only_products(product_ids)
    |> group_by([s, l], [l.product_id, s.lot_id])
    |> select([s, l], {l.product_id, s.lot_id, sum(s.quantity)})
    |> Repo.all()
    |> Enum.group_by(fn {product_id, _lot_id, _quantity} -> product_id end)
    |> Map.new(fn {product_id, rows} -> {product_id, weigh(rows, costs)} end)
  end

  defp maybe_only_products(query, nil), do: query
  defp maybe_only_products(query, ids), do: where(query, [s, l], l.product_id in ^ids)

  defp weigh(rows, costs) do
    {value, priced, unpriced} =
      Enum.reduce(rows, {Decimal.new(0), Decimal.new(0), Decimal.new(0)}, fn
        {_product_id, lot_id, quantity}, {value, priced, unpriced} ->
          case costs[lot_id] do
            nil ->
              {value, priced, Decimal.add(unpriced, quantity)}

            cost ->
              {Decimal.add(value, Decimal.mult(cost, quantity)), Decimal.add(priced, quantity),
               unpriced}
          end
      end)

    %{
      average: if(Decimal.compare(priced, 0) == :gt, do: Decimal.div(value, priced), else: nil),
      known_value: value,
      priced_quantity: priced,
      unpriced_quantity: unpriced,
      quantity: Decimal.add(priced, unpriced)
    }
  end

  @doc """
  Balance derived straight from the ledger.

  Accepts `:lot_id`, `:box_id`, `:location_id` and `:product_id` filters; with
  no filters it sums the whole ledger (which should be the total stock on hand).
  """
  def balance(filters \\ []) do
    TransactionEntry
    |> filter_entries(filters)
    |> select([e], coalesce(sum(e.quantity), 0))
    |> Repo.one()
  end

  @doc """
  Balance read from the snapshot cache. Same number as `balance/1`, cheaper.
  """
  def cached_balance(filters \\ []) do
    StockSnapshot
    |> filter_snapshots(filters)
    |> select([s], coalesce(sum(s.quantity), 0))
    |> Repo.one()
  end

  @doc """
  Balances per lot for a product, newest expiry last, skipping empty lots.

  This is the FEFO (first-expiry-first-out) ordering used as the default
  picking suggestion. Lots with no expiry date go last: an unknown expiry is
  not a reason to hand out stock first.
  """
  def lot_balances(product_id, filters \\ []) do
    filters = Keyword.put(filters, :product_id, product_id)

    TransactionEntry
    |> filter_entries(filters)
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> group_by([e, l], [l.id, l.lot_number, l.expires_on])
    |> having([e], sum(e.quantity) > 0)
    |> order_by([e, l], asc_nulls_last: l.expires_on, asc: l.id)
    |> select([e, l], %{
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      quantity: sum(e.quantity)
    })
    |> Repo.all()
  end

  @doc """
  Stock positions of a product at a location — lot *and* box — oldest expiry
  first, skipping empty ones.

  Picking must know the box: an entry that forgets which box the goods came out
  of makes that box's balance wrong.
  """
  def position_balances(product_id, opts \\ []) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, l], l.product_id == ^product_id)
    |> maybe_at_location(opts[:location_id])
    |> maybe_loose_only(opts[:loose_only])
    |> maybe_at_box(opts[:box_id])
    |> maybe_lot(opts[:lot_id])
    |> group_by([e, l], [l.id, l.lot_number, l.expires_on, e.box_id, e.location_id])
    |> having([e], sum(e.quantity) > 0)
    |> order_by([e, l], asc_nulls_last: l.expires_on, asc: l.id)
    |> select([e, l], %{
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      box_id: e.box_id,
      location_id: e.location_id,
      quantity: sum(e.quantity)
    })
    |> Repo.all()
  end

  defp maybe_at_location(query, nil), do: query
  defp maybe_at_location(query, id), do: where(query, [e], e.location_id == ^id)

  defp maybe_loose_only(query, true), do: where(query, [e], is_nil(e.box_id))
  defp maybe_loose_only(query, _), do: query

  # Pins FEFO to one box (the write-off screen's override).
  defp maybe_at_box(query, nil), do: query
  defp maybe_at_box(query, id), do: where(query, [e], e.box_id == ^id)

  # Pins to one lot: with no expiry (shirts) FEFO falls back to lot id and the
  # seller knows better.
  defp maybe_lot(query, nil), do: query
  defp maybe_lot(query, id), do: where(query, [e], e.lot_id == ^id)

  @doc """
  How much of a product sits in each box at a location, loose stock last.

  Grouped by box rather than by lot, for conferring before picking
  (`position_balances/2` is the FEFO pick source). `expires_on` is the earliest
  among the box's lots.
  """
  def box_quantities(product_id, location_id) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> join(:left, [e], b in Box, on: b.id == e.box_id)
    |> where([e, l], l.product_id == ^product_id)
    |> maybe_at_location(location_id)
    |> group_by([e, l, b], [e.box_id, b.code])
    |> having([e], sum(e.quantity) > 0)
    |> order_by([e, l, b], asc_nulls_last: b.code)
    |> select([e, l, b], %{
      box_id: e.box_id,
      box_code: b.code,
      quantity: sum(e.quantity),
      expires_on: min(l.expires_on)
    })
    |> Repo.all()
  end

  @doc """
  Positions to draw `quantity` of a product from, oldest expiry first.

  Returns `{:ok, picks}` or `{:insufficient_stock, picks, missing}`.

  Not an `{:error, _}`: this is a question, and a short answer with what *is*
  available is useful. The commands that act on it (`Outbound.issue/3`,
  `Kits.assemble/3`) translate it into
  `{:error, {:insufficient_stock, %{missing: missing, item: item_or_nil}}}`.
  """
  def suggest_fefo_positions(product_id, quantity, opts \\ []) do
    quantity = Decimal.new(quantity)

    {picks, remaining} =
      product_id
      |> position_balances(opts)
      |> Enum.reduce({[], quantity}, fn position, {picks, remaining} ->
        if Decimal.compare(remaining, 0) == :gt do
          taken = Decimal.min(remaining, position.quantity)
          {[Map.put(position, :take, taken) | picks], Decimal.sub(remaining, taken)}
        else
          {picks, remaining}
        end
      end)

    picks = Enum.reverse(picks)

    if Decimal.compare(remaining, 0) == :gt do
      {:insufficient_stock, picks, remaining}
    else
      {:ok, picks}
    end
  end

  @doc """
  Suggests which lots to pick, oldest expiry first, until `quantity` is met.

  Returns `{:ok, picks}` or `{:insufficient_stock, picks, missing}` — the
  caller decides whether to block or to let a human override.
  """
  def suggest_fefo_picks(product_id, quantity, filters \\ []) do
    quantity = Decimal.new(quantity)

    {picks, remaining} =
      product_id
      |> lot_balances(filters)
      |> Enum.reduce({[], quantity}, fn lot, {picks, remaining} ->
        if Decimal.compare(remaining, 0) == :gt do
          taken = Decimal.min(remaining, lot.quantity)
          {[Map.put(lot, :take, taken) | picks], Decimal.sub(remaining, taken)}
        else
          {picks, remaining}
        end
      end)

    picks = Enum.reverse(picks)

    if Decimal.compare(remaining, 0) == :gt do
      {:insufficient_stock, picks, remaining}
    else
      {:ok, picks}
    end
  end

  @doc """
  Rebuilds the whole snapshot table from the ledger.

  The cache is disposable by design; this exists for repairs and for the test
  that proves cache and ledger never disagree.
  """
  def recalculate_snapshots do
    Repo.transaction(fn ->
      Repo.delete_all(StockSnapshot)

      now = DateTime.utc_now(:second)

      rows =
        TransactionEntry
        |> group_by([e], [e.lot_id, e.box_id, e.location_id])
        |> select([e], %{
          lot_id: e.lot_id,
          box_id: e.box_id,
          location_id: e.location_id,
          quantity: sum(e.quantity)
        })
        |> Repo.all()
        |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

      {count, _} = Repo.insert_all(StockSnapshot, rows)
      count
    end)
  end

  defp apply_entries_to_snapshots(repo, %{transaction: transaction}) do
    now = DateTime.utc_now(:second)

    snapshots =
      Enum.map(transaction.entries, fn entry ->
        repo.insert!(
          %StockSnapshot{
            lot_id: entry.lot_id,
            box_id: entry.box_id,
            location_id: entry.location_id,
            quantity: entry.quantity,
            inserted_at: now,
            updated_at: now
          },
          on_conflict: [inc: [quantity: entry.quantity], set: [updated_at: now]],
          conflict_target: [:lot_id, :box_id, :location_id]
        )
      end)

    {:ok, snapshots}
  end

  defp ensure_balances_are_not_negative(repo, %{transaction: transaction}) do
    if transaction.type in @types_allowed_to_go_negative do
      {:ok, []}
    else
      negative =
        transaction.entries
        |> Enum.map(&{&1.lot_id, &1.box_id, &1.location_id})
        |> Enum.uniq()
        |> Enum.filter(fn {lot_id, box_id, location_id} ->
          quantity =
            StockSnapshot
            |> where([s], s.lot_id == ^lot_id and s.location_id == ^location_id)
            |> box_scope(box_id)
            |> select([s], coalesce(sum(s.quantity), 0))
            |> repo.one()

          Decimal.compare(quantity, 0) == :lt
        end)

      if negative == [] do
        {:ok, []}
      else
        {:error, {:negative_stock, negative}}
      end
    end
  end

  defp box_scope(query, nil), do: where(query, [s], is_nil(s.box_id))
  defp box_scope(query, box_id), do: where(query, [s], s.box_id == ^box_id)

  defp filter_entries(query, filters) do
    Enum.reduce(filters, query, fn
      {:lot_id, id}, query -> where(query, [e], e.lot_id == ^id)
      # box_id: nil means in no box; "= NULL" would match nothing.
      {:box_id, nil}, query -> where(query, [e], is_nil(e.box_id))
      {:box_id, id}, query -> where(query, [e], e.box_id == ^id)
      {:location_id, id}, query -> where(query, [e], e.location_id == ^id)
      {:product_id, id}, query -> where(query, [e], e.lot_id in subquery(lot_ids(id)))
    end)
  end

  defp filter_snapshots(query, filters) do
    Enum.reduce(filters, query, fn
      {:lot_id, id}, query -> where(query, [s], s.lot_id == ^id)
      {:box_id, nil}, query -> where(query, [s], is_nil(s.box_id))
      {:box_id, id}, query -> where(query, [s], s.box_id == ^id)
      {:location_id, id}, query -> where(query, [s], s.location_id == ^id)
      {:product_id, id}, query -> where(query, [s], s.lot_id in subquery(lot_ids(id)))
    end)
  end

  defp lot_ids(product_id) do
    Lot
    |> where([l], l.product_id == ^product_id)
    |> select([l], l.id)
  end
end
