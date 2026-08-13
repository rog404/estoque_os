defmodule EstoqueOS.Reports.ProductHistory do
  @moduledoc """
  Everything that ever happened to one product.

  The question "what happened to this gauze" could only be answered by reading
  three screens and joining them by eye: the stock list said how much there is,
  the invoices said what was bought, the audit report said what moved on a given
  day. None of them was about the product.

  It is also the question an auditor asks. A ledger that can only be read by
  period is a ledger nobody can interrogate about a specific item — and a recall
  is exactly that question, asked urgently.

  Its own module rather than more of `Reports`, which is already the largest
  context in the project and is heading the same way `Inventory` did.
  """

  import Ecto.Query

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.{Lot, StockSnapshot, Transaction, TransactionEntry}
  alias EstoqueOS.Repo

  @doc """
  The product, where its stock is now, and every movement that touched it.

  `movements` is capped: a product bought weekly for five years has thousands of
  lines and nobody reads past the first page. The cap is stated on screen rather
  than silently truncating.
  """
  def for_product(product_id, opts \\ []) do
    product = Repo.get!(Product, product_id)
    limit = opts[:limit] || 100

    %{
      product: product,
      positions: positions(product_id),
      movements: movements(product_id, limit),
      movement_count: movement_count(product_id),
      costs: costs(product_id),
      limit: limit
    }
  end

  @doc """
  Where this product physically is right now, lot by lot.

  Empty positions are left out: a lot that ran to zero is history, and history is
  what the movement list is for.
  """
  def positions(product_id) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:left, [s], b in EstoqueOS.Inventory.Box, on: b.id == s.box_id)
    |> join(:inner, [s], loc in EstoqueOS.Inventory.Location, on: loc.id == s.location_id)
    |> where([s, l], l.product_id == ^product_id and s.quantity != 0)
    |> order_by([s, l], asc_nulls_last: l.expires_on, asc: l.lot_number)
    |> select([s, l, b, loc], %{
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      needs_review: l.needs_review,
      box: b.code,
      box_id: b.id,
      location: loc.name,
      location_id: loc.id,
      quantity: s.quantity
    })
    |> Repo.all()
  end

  # Every entry touching a lot of this product, newest first. Signed, so a reader
  # can tell an arrival from a departure without decoding the type.
  defp movements(product_id, limit) do
    TransactionEntry
    |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, t, l], l.product_id == ^product_id)
    |> order_by([e, t], desc: t.occurred_at, desc: t.id, desc: e.id)
    |> limit(^limit)
    |> preload([e, t],
      transaction:
        {t, [:user, :source_location, :destination_location, :mission, invoice: :supplier]}
    )
    |> preload([e], [:box, :location, lot: :product])
    |> Repo.all()
  end

  defp movement_count(product_id) do
    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where([e, l], l.product_id == ^product_id)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  @doc """
  What was paid per unit over time, newest first.

  This is the number the whole system exists to produce, so it is worth being
  able to see it move: a price that doubled between two invoices is a
  conversation with a supplier, and it is invisible in an average.

  Entries with no cost are left out rather than shown as zero — a donation was
  not free, its value was never informed.
  """
  def costs(product_id, opts \\ []) do
    TransactionEntry
    |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> where(
      [e, t, l],
      l.product_id == ^product_id and e.quantity > 0 and not is_nil(e.unit_cost)
    )
    |> order_by([e, t], desc: t.occurred_at, desc: e.id)
    |> limit(^(opts[:limit] || 20))
    |> preload([e, t], transaction: {t, [invoice: :supplier]})
    |> select([e, t, l], %{
      entry: e,
      occurred_at: t.occurred_at,
      transaction: t,
      lot_number: l.lot_number,
      unit_cost: e.unit_cost,
      quantity: e.quantity
    })
    |> Repo.all()
  end
end
