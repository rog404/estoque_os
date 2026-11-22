defmodule EstoqueOS.Alerts do
  @moduledoc """
  What needs somebody's attention (expiring stock, below minimum, stale boxes,
  divergent counts, lots with no number), with a count and a path for each.

  Divergent counts and numberless lots can be *closed*: an authorized person
  records that they looked, the alert leaves the list, and the acknowledgement
  stays on the row for audit. `review_reason` and `needs_review` are never
  reset; they are facts about what happened.
  """

  import Ecto.Query
  import EstoqueOS.Coercion, only: [blank_to_nil: 1]

  alias EstoqueOS.Accounts.{Scope, User}
  alias EstoqueOS.Inventory.{Lot, Transaction}
  alias EstoqueOS.Repo
  alias EstoqueOS.Reports

  @doc """
  Everything open, for the scope looking. Each entry carries kind, count and
  the path where it is resolved.
  """
  def pending(scope, opts \\ []) do
    segment = Scope.default_segment(scope)
    surgical? = segment != "marketing"

    [
      counts_alert(surgical?),
      lots_alert(segment),
      expiring_alert(segment, opts),
      below_minimum_alert(segment),
      stale_boxes_alert(surgical?)
    ]
    |> Enum.reject(&(&1 == nil or &1.count == 0))
  end

  # A box belongs to no segment, so counts are the surgical operation's.
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
  The open divergent counts, newest first. Reuses the overview's list so the
  bell and the dashboard never disagree.
  """
  def list_open_counts(opts \\ []), do: Reports.counts_needing_review(opts)

  @doc """
  The open lots with no number, newest first: the latest arrival is the one
  somebody can still walk over and read.
  """
  def list_open_lots(scope, opts \\ []) do
    scope
    |> Scope.default_segment()
    |> open_lots()
    |> order_by([l], desc: l.id)
    |> limit(^(opts[:limit] || 5))
    |> select([l, p], %{id: l.id, product: p.name, product_id: p.id})
    |> Repo.all()
  end

  @doc """
  Records that somebody looked at a divergent count and accepted it.

  Only the roles that decide what to do about a divergence may close one; the
  counter who found it may not.
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

  Same gate as the minimum-stock field and kit recipes. Never while viewing as
  another role: an acknowledgement carries the name of whoever actually looked.
  """
  def may_acknowledge?(scope) do
    not Scope.viewing_as?(scope) and Scope.effective_role(scope) in User.roles_that_plan()
  end

  @doc """
  Whether this scope is shown the bell at all.

  These are the manager's alerts: logistics and auditor cannot act on them, and
  a number nobody can close gets ignored. The borrowed role decides, so an admin
  viewing as auditor loses the bell.
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
