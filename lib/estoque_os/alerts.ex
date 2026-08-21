defmodule EstoqueOS.Alerts do
  @moduledoc """
  What needs somebody's attention, in one place.

  The pieces were all here already — expiring stock, products below their
  minimum, boxes nobody has counted, a count that disagreed twice, a lot that
  arrived with no number — but each of them lived on its own strip of the
  overview, and the ones at the bottom were not being read. This gathers them so
  the app can say *how many* things are open from any screen, and lead to each
  of them.

  Two of them can be *closed*, and that is the other half of this module. A
  count that disagreed twice and a lot with no number are both correct to raise
  and both sometimes simply the answer: the box really did have 27, and the
  blanket a volunteer brought really has no lot printed on it. Somebody with the
  authority to say so records that they looked, the alert leaves the list, and
  the acknowledgement stays on the row — an auditor asking "who signed off on
  this divergence" gets a name and a date rather than a silence.

  Nothing is deleted and no flag is flipped back: `review_reason` and
  `needs_review` are facts about what happened, and they stay true.
  """

  import Ecto.Query
  import EstoqueOS.Coercion, only: [blank_to_nil: 1]

  alias EstoqueOS.Accounts.{Scope, User}
  alias EstoqueOS.Inventory.{Lot, Transaction}
  alias EstoqueOS.Repo
  alias EstoqueOS.Reports

  @doc """
  Everything open, for the scope looking.

  Each entry carries what it is, how many, and where it is resolved — the
  counter is only useful if the number leads somewhere.
  """
  def pending(scope, opts \\ []) do
    segment = Scope.segment(scope)
    surgical? = is_nil(segment)

    [
      counts_alert(surgical?),
      lots_alert(segment),
      expiring_alert(segment, opts),
      below_minimum_alert(segment),
      stale_boxes_alert(surgical?)
    ]
    |> Enum.reject(&(&1 == nil or &1.count == 0))
  end

  # A divergent count is about a box, and a box belongs to no segment — so this
  # one is the surgical operation's, like the boxes themselves.
  defp counts_alert(false), do: nil

  defp counts_alert(true) do
    %{
      kind: :counts,
      count: Repo.aggregate(open_counts(), :count),
      path: "/",
      severity: :high
    }
  end

  defp lots_alert(segment) do
    %{
      kind: :lots,
      count: Repo.aggregate(open_lots(segment), :count),
      path: "/stock?review=on",
      severity: :medium
    }
  end

  defp expiring_alert(segment, opts) do
    %{
      kind: :expiring,
      count: length(Reports.expiring_soon(limit: opts[:limit] || 50, segment: segment)),
      path: "/stock?expiring=on",
      severity: :medium
    }
  end

  # Lands on the stock already filtered to what is short, the way the expiring
  # and the missing-lot alerts always did. It used to open the whole stock and
  # leave the reader to find the rows the number was about; the filter it needed
  # exists now.
  defp below_minimum_alert(segment) do
    %{
      kind: :below_minimum,
      count: length(Reports.below_minimum(limit: 50, segment: segment)),
      path: "/stock?below_minimum=on",
      severity: :low
    }
  end

  defp stale_boxes_alert(false), do: nil

  defp stale_boxes_alert(true) do
    %{
      kind: :stale_boxes,
      count: length(Reports.stale_boxes(limit: 50)),
      path: "/boxes",
      severity: :low
    }
  end

  @doc "Counts that disagreed twice and nobody has accepted yet."
  def open_counts do
    from t in Transaction,
      where: not is_nil(t.review_reason) and is_nil(t.review_acknowledged_at)
  end

  @doc "Lots that arrived with no number and nobody has accepted yet."
  def open_lots(segment \\ nil) do
    query =
      from l in Lot,
        join: p in assoc(l, :product),
        where: l.needs_review and is_nil(l.review_acknowledged_at)

    case segment do
      nil -> query
      segment -> where(query, [_l, p], p.segment == ^segment)
    end
  end

  @doc """
  The open divergent counts themselves, newest first, for the panel that closes
  them.

  Reuses the overview's own list so the bell and the dashboard can never
  disagree about what is open.
  """
  def list_open_counts(opts \\ []), do: Reports.counts_needing_review(opts)

  @doc """
  The open lots with no number, for the same panel.

  Newest first: a lot that arrived this morning is the one somebody can still
  walk over and read the box of.
  """
  def list_open_lots(scope, opts \\ []) do
    scope
    |> Scope.segment()
    |> open_lots()
    |> order_by([l], desc: l.id)
    |> limit(^(opts[:limit] || 5))
    |> select([l, p], %{id: l.id, product: p.name, product_id: p.id})
    |> Repo.all()
  end

  @doc """
  Records that somebody looked at a divergent count and accepted it.

  Only the roles that decide what to do about a divergence — chase the
  supplier, or accept the loss — may close one. The counter who found it is
  exactly the person whose word is not enough here.
  """
  def acknowledge_count(id, scope, note \\ nil) do
    acknowledge(Transaction, id, scope, %{
      review_acknowledged_at: DateTime.utc_now(:second),
      review_acknowledged_by_id: user_id(scope),
      review_acknowledgement: blank_to_nil(note)
    })
  end

  @doc "Records that somebody accepted a lot arriving with no number."
  def acknowledge_lot(id, scope) do
    acknowledge(Lot, id, scope, %{
      review_acknowledged_at: DateTime.utc_now(:second),
      review_acknowledged_by_id: user_id(scope)
    })
  end

  @doc """
  Whether this scope may close an alert.

  The same gate the minimum-stock field and the kit recipe sit behind: a
  planning decision, argued with the ONG team, and not the counter's to make
  alone. And never while wearing somebody else's role — an acknowledgement
  carries a name, and it has to be the name of whoever actually looked.
  """
  def may_acknowledge?(scope) do
    not Scope.viewing_as?(scope) and Scope.effective_role(scope) in User.roles_that_plan()
  end

  @doc """
  Whether this scope is shown the bell at all.

  Asked for by name, and it is the same sentence as `may_acknowledge?/1` with
  the borrowing clause removed: these are the manager's alerts. The logistics
  operator counts the box they are holding and the auditor reads; neither can
  act on "four counts did not agree", and a number nobody can close is a number
  people learn to walk past.

  The borrowed role decides, which is what borrowing one is for: an admin
  standing in the auditor's shoes stops seeing the bell, because the auditor
  does not have one.
  """
  def visible_to?(scope), do: Scope.effective_role(scope) in User.roles_that_plan()

  defp acknowledge(schema, id, scope, attrs) do
    if may_acknowledge?(scope) do
      case Repo.get(schema, id) do
        nil ->
          {:error, :not_found}

        record ->
          record |> Ecto.Changeset.change(attrs) |> Repo.update()
      end
    else
      {:error, :not_allowed}
    end
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil
end
