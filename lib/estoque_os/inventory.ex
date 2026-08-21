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

  Donated toys, a box somebody handed over at the door: real stock, no document,
  no price. It posts `donation_in` because that is what it is — and because the
  reports already separate that from `purchase_in`, so what was given is never
  counted as what was bought.

  `unit_cost` is left NULL, deliberately and always. Nobody can price a used
  donated toy, and a symbolic centavo in the ledger would drag average cost and
  stock value toward a number nobody paid. The screens that must show a figure
  declare R$ 0,01 themselves.

  Quantity is in the product's own stock unit. There is no packaging conversion
  here: an invoice states "2 boxes of 100" and needs a factor, while a person
  holding the goods counts the things.
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

  # A box is where it physically is. Writing an entry that puts goods at location
  # A inside a box that sits at location B makes the same stock count twice — at
  # A by location and at B by box — and no recount can tell which half is real.
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

  # Where the goods came from, and therefore what they are worth.
  #
  # A donation has **no** cost — nil, never zero and never the symbolic cent the
  # old spreadsheet used, because both poison an average and a stock value
  # (SPEC §4.7). Reports say "valor não informado" and mean it.
  #
  # Goods bought without an invoice are a different animal with the same paperwork:
  # somebody paid for them, and that price is real. It arrives as either a unit
  # price or a total — whichever the receipt in the operator's hand happens to
  # state — and the total is divided by what actually came in.
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

  # A lot number that is already on record for this product is the same lot, not
  # a second one: two rows for "L-4471" would split the balance and hide half of
  # it from a recall.
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

  # A missing lot number is two different facts, the same way a missing expiry
  # date is. On gauze it means nobody read the pack; on a blanket a volunteer
  # brought there is nothing to read, and flagging that fills the review list
  # with items nobody can ever resolve — which is how the list stops being read.
  # `products.lot_expected` is what tells them apart.
  defp lot_expected?(product_id) do
    case Repo.one(from p in Product, where: p.id == ^product_id, select: p.lot_expected) do
      nil -> true
      expected -> expected
    end
  end

  # Joining a known lot, the operator may be reading an expiry date off the goods
  # that the lot never had recorded — that fills a blank and is worth keeping. A
  # date that disagrees with the one on record is a different matter: one of the
  # two is wrong, and silently picking either would put the wrong batch in front
  # of a recall.
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

  `unpriced_lines` is counted rather than hidden: donated goods carry no cost,
  and a certificate that showed their value as zero would be understating what
  was handed over.
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

  Products with nothing there are absent from the map rather than zero, so the
  caller decides what "none" means; `Map.get(balances, id, Decimal.new(0))` is
  usually it.
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

  A separate question from `balances_by_product/2` and asked by a different
  caller: assembling a kit is refused while any of its components has expired
  stock here (see `EstoqueOS.Kits.assemble/3`), because a kit is sealed and
  what is inside it stops being visible. Products with nothing expired are
  absent from the map.

  `on_date` defaults to today. Passed in so a caller can ask the question of a
  date other than now, and so the tests do not have to travel in time.
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

  The list a person standing in front of the shelf reads. It is deliberately
  built from what is *there* rather than from the catalog: a product with
  nothing at this location has no business being offered to somebody about to
  take goods out of it, and a zero row is an invitation to a write-off that
  cannot complete.

  `> 0` and not `!= 0` on purpose. A negative balance is a bug or a pending
  correction, and either way it is not something anyone can pick up and carry
  away.
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

  # Where to physically reach for it. The list said what was at the location and
  # not where it was, which on a shelf of forty boxes is most of the work.
  #
  # A second query rather than an aggregate on the first: the balance that
  # decides whether a *box* still holds any of a product is a different grouping
  # from the one that totals the product across the location, and doing both at
  # once means one of them is wrong.
  # Which stock the caller may see, passed down from the scope. A screen that
  # lists "what is here" has to answer it per role, or the marketing person is
  # offered a surgical product to write off.
  defp maybe_segment(query, nil), do: query
  defp maybe_segment(query, ""), do: query
  defp maybe_segment(query, segment), do: where(query, [_e, _l, p], p.segment == ^segment)

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

  Entries with no cost — donations, where no value was ever informed — are left
  out rather than counted as zero, which would drag the average toward a price
  nobody paid.
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

  The same gauze arrives on three invoices at three prices. This is the single
  number to put beside it: a **weighted moving average** over the stock on hand,
  each lot's own average cost weighted by how much of that lot is still here.
  Not FIFO — the picking is FEFO, so a FIFO cost would describe goods that are
  not the ones leaving.

  Two things this is careful about, and they are the whole reason it returns a
  map instead of a number:

  Donated stock has **no** cost — nil, never zero (SPEC §4.7). Counting it as
  zero would drag the average down and quietly understate every value built on
  it, so it is excluded from the average and reported separately as
  `unpriced_quantity`. An average over 30% unpriced stock is a number that needs
  its caveat attached, and the caller cannot attach it without being told.

  And this is a **read-model**. It is derived on demand and never written back
  into `transaction_entries`, which keep the price they actually entered at.
  That is the auditor's trail, and it is the thing this must not touch.

  `average` is nil when nothing on hand has a known cost — which is honest, and
  different from zero.
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

  Picking has to know the box: at a mission everything is inside boxes, and an
  entry that forgets which box the goods came out of quietly makes that box's
  balance wrong.
  """
  def position_balances(product_id, opts \\ []) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, l], l.product_id == ^product_id)
    |> maybe_at_location(opts[:location_id])
    |> maybe_loose_only(opts[:loose_only])
    |> maybe_at_box(opts[:box_id])
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

  # Lets a caller pin FEFO to one box rather than the whole location — the
  # write-off screen's "take it from here specifically" override.
  defp maybe_at_box(query, nil), do: query
  defp maybe_at_box(query, id), do: where(query, [e], e.box_id == ^id)

  @doc """
  How much of a product sits in each box at a location, loose stock last.

  `position_balances/2` answers "from where do I pick" for FEFO; this answers
  "where do I go stand" for a person conferring a list before they pick
  anything — grouped by box rather than by lot. `expires_on` is the earliest
  among whatever lots are in that box, so a caller can still say which one to
  recommend without a second query.
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

  Deliberately not an `{:error, _}` tuple: this asks a question rather than
  performing an action, and a short answer with what *is* available is a useful
  answer. The commands that act on it (`Outbound.issue/3`, `Kits.assemble/3`)
  translate it into the one error shape the callers handle:
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
      # box_id: nil asks for the goods that are in no box yet — "= NULL" would
      # silently match nothing instead.
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
