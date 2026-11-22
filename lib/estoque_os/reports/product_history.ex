defmodule EstoqueOS.Reports.ProductHistory do
  @moduledoc """
  Everything that ever happened to one product.

  Answers "what happened to this gauze": the auditor's question, and a recall's.
  A ledger readable only by period cannot be interrogated about one item.

  Its own module to keep `Reports` from growing further.
  """

  import Ecto.Query

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.{Lot, StockSnapshot, Transaction, TransactionEntry}
  alias EstoqueOS.Repo

  @doc """
  The product, where its stock is now, and every movement that touched it.

  `movements` is capped (nobody reads past the first page); the screen states
  the cap rather than truncating silently.
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

  Empty positions are left out; history is the movement list's job.
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

  # Newest first, signed so arrivals and departures are distinguishable.
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

  Shows the price moving, which an average hides. Entries with no cost are left
  out, not zero: a donation's value was never informed.
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
