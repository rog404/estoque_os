defmodule EstoqueOS.Auditing do
  @moduledoc """
  The guided mini-audit.

  A full inventory is never a precondition for anything here — in a mission
  storage room it is not even possible. What the operation can do is count a
  few boxes well, so the job is to answer "which box should I open first?" and
  then make recording that count cheap.

  Priority follows the SPEC, in order: controlled substances, then stock about
  to expire, then value at risk, then whatever has gone longest without being
  looked at. Every suggestion carries the reasons that put it there, because a
  ranking nobody understands is a ranking nobody follows.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Box, Locations, Lot, StockSnapshot}
  alias EstoqueOS.Repo

  @controlled_weight 1_000
  @expiring_weight 500
  # Value is capped so one expensive box cannot outrank a controlled one.
  @max_value_weight 300
  @value_per_point 100
  # A box nobody ever counted is treated as a year stale rather than infinity.
  @never_counted_days 365

  @doc """
  Boxes worth counting first, most urgent first.
  """
  def suggestions(opts \\ []) do
    horizon = Date.add(Date.utc_today(), opts[:expiry_days] || 90)
    costs = Inventory.average_unit_costs()

    contents_by_box()
    |> Enum.map(&score(&1, horizon, costs))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(opts[:limit] || 10)
  end

  @doc """
  The same ranking, keyed by box, for a screen that already has the boxes.

  The guided list used to be a page of its own, which meant the box list and the
  counting queue were two places saying different things about the same boxes.
  There is one list now — the boxes — and this is what puts it in the order
  somebody should work through: what is controlled, then what is expiring, then
  what is worth the most, then what has gone longest unlooked-at. A box with no
  contents is not in here at all; there is nothing in it to count.
  """
  def priorities(opts \\ []) do
    horizon = Date.add(Date.utc_today(), opts[:expiry_days] || 90)
    costs = Inventory.average_unit_costs()

    contents_by_box()
    |> Enum.map(&score(&1, horizon, costs))
    |> Map.new(&{&1.box.id, &1})
  end

  defp contents_by_box do
    StockSnapshot
    |> join(:inner, [s], b in Box, on: b.id == s.box_id)
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, _b, l], p in Product, on: p.id == l.product_id)
    |> where([s], not is_nil(s.box_id) and s.quantity != 0)
    |> where([s, b], b.active)
    |> select([s, b, l, p], %{
      box: b,
      lot_id: l.id,
      expires_on: l.expires_on,
      controlled: p.controlled,
      quantity: s.quantity
    })
    |> Repo.all()
    |> Enum.group_by(& &1.box.id)
    |> Enum.map(fn {_box_id, [%{box: box} | _] = rows} ->
      {Repo.preload(box, :location), rows}
    end)
  end

  defp score({box, rows}, horizon, costs) do
    controlled = Enum.filter(rows, & &1.controlled)
    expiring = Enum.filter(rows, &(&1.expires_on && Date.compare(&1.expires_on, horizon) != :gt))
    days_stale = days_since_verified(box)

    value =
      Enum.reduce(rows, Decimal.new(0), fn row, total ->
        case costs[row.lot_id] do
          nil -> total
          cost -> Decimal.add(total, Decimal.mult(cost, row.quantity))
        end
      end)

    score =
      controlled_points(controlled) + expiring_points(expiring) + value_points(value) +
        days_stale

    %{
      box: box,
      score: score,
      quantity: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.quantity)),
      positions: length(rows),
      value: value,
      controlled_count: length(controlled),
      expiring_count: length(expiring),
      days_since_verified: days_stale,
      never_counted: is_nil(box.last_verified_at),
      reasons: reasons(controlled, expiring, days_stale, box)
    }
  end

  defp controlled_points([]), do: 0
  defp controlled_points(_controlled), do: @controlled_weight

  defp expiring_points([]), do: 0
  defp expiring_points(_expiring), do: @expiring_weight

  defp value_points(value) do
    value
    |> Decimal.div(@value_per_point)
    |> Decimal.round(0, :down)
    |> Decimal.to_integer()
    |> min(@max_value_weight)
  end

  defp days_since_verified(%{last_verified_at: nil}), do: @never_counted_days

  defp days_since_verified(%{last_verified_at: verified_at}) do
    DateTime.utc_now() |> DateTime.diff(verified_at, :day) |> max(0)
  end

  defp reasons(controlled, expiring, days_stale, box) do
    [
      controlled != [] &&
        {:controlled, gettext("%{count} controlled item(s)", count: length(controlled))},
      expiring != [] &&
        {:expiring, gettext("%{count} lot(s) close to expiry", count: length(expiring))},
      is_nil(box.last_verified_at) && {:never_counted, gettext("never counted")},
      box.last_verified_at && days_stale > 30 &&
        {:stale, gettext("%{days} days without a count", days: days_stale)}
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  What to put on the counting sheet for a box: what the ledger presumes is in
  there, so the person counting can confirm or correct each line.
  """
  def count_sheet(%Box{} = box) do
    Locations.box_contents(box)
  end

  @doc """
  Records a count of a box.

  `counts` maps lot ids to what was actually found. Lots left out are not
  counted — they keep whatever the ledger presumed, exactly like an uncounted
  line in a receiving conference. A lot that is not supposed to be in the box
  may be included: finding something unexpected is a normal outcome of a
  count, not an error.

  Everything is posted as one adjustment with reason `count_correction`, and
  the box is stamped as verified — which is what turns its balance from
  presumed into verified.
  """
  def record_count(%Box{} = box, counts, opts \\ []) do
    entries = count_entries(box, counts)

    Multi.new()
    |> then(fn multi ->
      if entries == [] do
        multi
      else
        Multi.run(multi, :transaction, fn _repo, _changes ->
          Inventory.post_transaction(%{
            type: "adjustment",
            reason_code: "count_correction",
            user_id: opts[:user_id],
            notes: opts[:notes] || count_notes(box, opts),
            review_reason: opts[:review_reason],
            entries: entries
          })
        end)
      end
    end)
    |> Multi.run(:box, fn _repo, _changes -> Locations.mark_box_verified(box) end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        {:ok,
         %{
           box: changes.box,
           transaction: changes[:transaction],
           counted: map_size(counts),
           adjusted: length(entries)
         }}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # What the count was, said in the ledger where it cannot be edited later.
  #
  # A count taken with the expected figures on screen is a different measurement
  # from a blind one, and six months on nobody will remember which this was. If
  # it is not written down here it is not written down anywhere.
  defp count_notes(box, opts) do
    [
      gettext("Count of box %{code}", code: box.code),
      opts[:recounted] && gettext("counted twice"),
      opts[:revealed] && gettext("expected quantities were shown to the counter")
    ]
    |> Enum.reject(&(!&1))
    |> Enum.join(" · ")
  end

  @doc """
  What a set of counts would change, without changing anything.

  The screen asks this before it writes, so the operator confirms real numbers
  rather than an intention — and so a second count can be compared against the
  first without either of them having been posted.

  Lines absent from `counts` are absent from the answer: not counted is not the
  same as counted zero, and that distinction is the whole reason partial counts
  are allowed at all.
  """
  def preview_count(%Box{} = box, counts) do
    counts
    |> Enum.map(fn {lot_id, counted} ->
      lot_id = to_id(lot_id)
      counted = to_decimal(counted)
      presumed = Inventory.balance(lot_id: lot_id, box_id: box.id)

      %{
        lot_id: lot_id,
        counted: counted,
        presumed: presumed,
        difference: counted && Decimal.sub(counted, presumed)
      }
    end)
    |> Enum.reject(&is_nil(&1.counted))
  end

  @doc "The lines whose count disagrees with what the ledger presumed."
  def divergent(%Box{} = box, counts) do
    box |> preview_count(counts) |> Enum.reject(&Decimal.equal?(&1.difference, 0))
  end

  defp count_entries(box, counts) do
    counts
    |> Enum.map(fn {lot_id, counted} ->
      lot_id = to_id(lot_id)
      counted = to_decimal(counted)

      current = Inventory.balance(lot_id: lot_id, box_id: box.id)
      difference = Decimal.sub(counted, current)

      if Decimal.equal?(difference, 0) do
        nil
      else
        %{
          lot_id: lot_id,
          box_id: box.id,
          location_id: box.location_id,
          quantity: difference
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
