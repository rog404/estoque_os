defmodule EstoqueOS.Receiving do
  @moduledoc """
  Checking what physically arrived against what the invoice promised.

  Posting books what the supplier says they sent; the conference turns that
  into a fact: lines are counted, differences posted as adjustments with a
  reason, and goods put in a box (a balance becomes verified, not presumed).

  Counting may be partial: uncounted lines stay untouched, not recorded as zero.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Box
  alias EstoqueOS.Invoices.Invoice
  alias EstoqueOS.Receiving.{Receipt, ReceiptLine}
  alias EstoqueOS.Repo

  @doc """
  Opens a conference round for an invoice.

  Only a posted invoice can be conferred (nothing in stock to disagree with
  before that). A further round is allowed when a divergence smells like a
  miscount.
  """
  def start_receipt(%Invoice{} = invoice, attrs) do
    invoice = Repo.preload(invoice, items: [:product])

    cond do
      invoice.status != "posted" ->
        {:error, :invoice_not_posted}

      open_receipt(invoice) ->
        {:error, :receipt_already_open}

      true ->
        %Receipt{}
        |> Receipt.changeset(%{
          invoice_id: invoice.id,
          location_id: field(attrs, :location_id),
          counted_by_id: field(attrs, :user_id),
          round: next_round(invoice),
          status: "draft",
          lines: Enum.map(invoice.items, &line_attrs/1)
        })
        |> Repo.insert()
        |> case do
          {:ok, receipt} -> {:ok, load_receipt(receipt)}
          error -> error
        end
    end
  end

  defp line_attrs(item) do
    %{
      invoice_item_id: item.id,
      expected_quantity: Decimal.mult(item.commercial_quantity, item.conversion_factor)
    }
  end

  defp next_round(invoice) do
    Repo.one(from r in Receipt, where: r.invoice_id == ^invoice.id, select: count(r.id)) + 1
  end

  defp open_receipt(invoice) do
    Repo.one(from r in Receipt, where: r.invoice_id == ^invoice.id and r.status == "draft")
  end

  def get_receipt!(id), do: Receipt |> Repo.get!(id) |> load_receipt()

  def get_open_receipt(%Invoice{} = invoice) do
    case open_receipt(invoice) do
      nil -> nil
      receipt -> load_receipt(receipt)
    end
  end

  @doc """
  Deliveries still waiting to be checked, newest invoice first.

  The operator's starting list, reachable without the invoice screen's money gate.

  A row is an open round (with progress) or a posted invoice nobody has begun.
  A closed conference drops off: a recount is deliberate, started from the invoice.

  Carries no amounts: the role reading this must not see them, and the safest
  number to hide is the one never sent.
  """
  def list_pending do
    invoices =
      Invoice
      |> where([i], i.status == "posted")
      |> order_by([i], desc: i.issued_on, desc: i.id)
      |> preload(:supplier)
      |> Repo.all()

    lines = from(l in ReceiptLine, order_by: [asc: l.id])

    rounds =
      Receipt
      |> where([r], r.invoice_id in ^Enum.map(invoices, & &1.id))
      |> preload(lines: ^lines)
      |> Repo.all()
      |> Enum.group_by(& &1.invoice_id)

    invoices
    |> Enum.map(&pending_row(&1, Map.get(rounds, &1.id, [])))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_row(invoice, rounds) do
    open = Enum.find(rounds, &(&1.status == "draft"))
    closed = Enum.count(rounds, &(&1.status == "completed"))

    cond do
      open ->
        %{
          invoice: invoice,
          receipt: open,
          round: open.round,
          lines: length(open.lines),
          counted: Enum.count(open.lines, & &1.counted_quantity),
          closed_rounds: closed
        }

      closed > 0 ->
        nil

      true ->
        %{
          invoice: invoice,
          receipt: nil,
          round: length(rounds) + 1,
          lines: 0,
          counted: 0,
          closed_rounds: 0
        }
    end
  end

  def list_receipts(%Invoice{} = invoice) do
    Receipt
    |> where([r], r.invoice_id == ^invoice.id)
    |> order_by([r], desc: r.round)
    |> Repo.all()
    |> Enum.map(&load_receipt/1)
  end

  # Fixed line order: without `order_by` recording one line reshuffles the rest.
  defp load_receipt(receipt) do
    lines = from(l in ReceiptLine, order_by: [asc: l.id], preload: [:box, invoice_item: :product])

    Repo.preload(
      receipt,
      [:location, :counted_by, :invoice, lines: lines],
      force: true
    )
  end

  @doc "Lines counted so far that disagree with the invoice."
  def divergences(%Receipt{} = receipt) do
    receipt.lines
    |> Enum.filter(&ReceiptLine.diverges?/1)
    |> Enum.map(fn line ->
      %{
        line: line,
        description: line.invoice_item.description,
        product: line.invoice_item.product,
        expected: line.expected_quantity,
        counted: line.counted_quantity,
        difference: ReceiptLine.divergence(line)
      }
    end)
  end

  @doc """
  Lines nobody has counted at all.

  Not "lines with no count of record": a line whose first count disagreed has
  none either, but it is a different job (visited, waiting for a return to the
  shelf). See `awaiting_recount_lines/1`.
  """
  def uncounted_lines(%Receipt{} = receipt) do
    Enum.filter(receipt.lines, &(is_nil(&1.counted_quantity) and ReceiptLine.attempts(&1) == 0))
  end

  @doc "Lines counted once already and waiting to be counted again."
  def awaiting_recount_lines(%Receipt{} = receipt) do
    Enum.filter(receipt.lines, &ReceiptLine.awaiting_recount?/1)
  end

  @doc """
  How many times one line is counted before a number that disagrees with the
  invoice is believed.

  Three: the first disagreement is usually a miscount, best told apart while
  the operator still holds the box; the second could repeat the same misreading;
  by the third the number is the number.
  """
  def counts_required, do: 3

  @doc """
  Records one count of a line, and decides whether to believe it.

  Returns:

    * `{:recorded, line}` — the count agreed with the invoice, or it is the
      last count we are going to ask for. `counted_quantity` is set.
    * `{:recount, line}` — the count disagreed and there are counts left.
      Nothing is booked; the trail is kept and the line goes back to asking.
    * `{:error, reason}`.

  The box is written either way: the goods are where the operator put them.

  Nothing here reaches the ledger (a conference writes when it closes), so an
  unbelieved count costs an edit, not a permanent adjustment.
  """
  def record_count(%ReceiptLine{} = line, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    case to_decimal(attrs["counted_quantity"]) do
      nil ->
        {:error, :invalid_quantity}

      # Checked here, not in the changeset: a negative is a typo, and as an
      # attempt it would spend one of the three counts (`counted_quantity` is
      # only written on the last, so the constraint would not fire until then).
      counted when is_struct(counted, Decimal) ->
        if Decimal.negative?(counted) do
          {:error, :invalid_quantity}
        else
          do_record_count(line, counted, attrs["box_id"])
        end
    end
  end

  defp do_record_count(line, counted, box_id) do
    attempts = (line.count_attempts || []) ++ [counted]
    agrees? = Decimal.equal?(counted, line.expected_quantity)
    believed? = agrees? or length(attempts) >= counts_required()

    changes = %{"count_attempts" => attempts, "box_id" => box_id}
    changes = if believed?, do: Map.put(changes, "counted_quantity", counted), else: changes

    case line |> ReceiptLine.changeset(changes) |> Repo.update() do
      {:ok, updated} -> {if(believed?, do: :recorded, else: :recount), updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Records the count and the box for one line, believing whatever it is told.

  The way in for anything that is not an operator counting: a fixture, an
  import, a manager settling a line by hand. `record_count/2` is what the
  conference screen uses.
  """
  def update_line(%ReceiptLine{} = line, attrs) do
    line
    |> ReceiptLine.changeset(normalize(attrs))
    |> Repo.update()
  end

  @doc """
  Puts one line back to not-counted, so it can be counted again.

  Not `update_line(line, %{counted_quantity: nil})`: `normalize/1` drops a nil
  count on purpose, since an empty form field means "untouched", not "wrong".

  The box is kept (the quantity was mistyped, not the shelf). The earlier
  attempts are dropped too, or the next single count would land as the third
  and be believed on the spot.
  """
  def uncount_line(%ReceiptLine{} = line) do
    line
    |> ReceiptLine.changeset(%{counted_quantity: nil, count_attempts: []})
    |> Repo.update()
  end

  defp normalize(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update("counted_quantity", nil, &to_decimal/1)
    |> Enum.reject(fn {key, value} -> key == "counted_quantity" and is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Closes the conference and writes what it found into the ledger.

  Two things can happen per counted line, both as transactions and never as a
  balance edit: the goods move into the box they were stored in, and whatever
  the count still disagrees with the ledger about becomes an adjustment with
  reason `count_correction`. Boxes touched by the count have their
  `last_verified_at` refreshed — that is what makes their balance *verified*
  rather than presumed.
  """
  def complete_receipt(%Receipt{} = receipt, opts \\ []) do
    receipt = load_receipt(receipt)

    if receipt.status != "draft" do
      {:error, :receipt_not_open}
    else
      counted = Enum.reject(receipt.lines, &is_nil(&1.counted_quantity))

      Multi.new()
      |> maybe_post(:boxing, boxing_entries(counted, receipt), %{
        type: "transfer",
        source_location_id: receipt.location_id,
        destination_location_id: receipt.location_id,
        user_id: opts[:user_id],
        notes: gettext("Goods put away after the conference")
      })
      |> maybe_post(:corrections, correction_entries(counted, receipt), %{
        type: "adjustment",
        reason_code: "count_correction",
        user_id: opts[:user_id],
        invoice_id: receipt.invoice_id,
        # Raises this on the manager's overview: a thrice-counted disagreement is
        # missing goods or a wrong invoice, not the operator's to close. Same flag
        # as the box count, so there is one list.
        review_reason: review_reason(counted),
        notes:
          opts[:notes] ||
            gettext("Receiving conference of invoice %{number}, round %{round}",
              number: receipt.invoice.number,
              round: receipt.round
            )
      })
      |> Multi.update(:receipt, fn _changes ->
        Receipt.changeset(receipt, %{
          status: "completed",
          completed_at: DateTime.utc_now(:second)
        })
      end)
      |> Multi.run(:boxes, fn _repo, _changes -> verify_boxes(counted) end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} ->
          {:ok,
           %{
             receipt: load_receipt(changes.receipt),
             corrections: changes[:corrections],
             boxing: changes[:boxing]
           }}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp review_reason(lines) do
    if Enum.any?(lines, &ReceiptLine.diverged_after_recounts?/1) do
      "count_diverged_after_recounts"
    end
  end

  @doc """
  Counted lines that were counted more than once and still disagree with the
  invoice.

  Read by the conference screen and, via the flagged transaction, the manager's overview.
  """
  def diverged_after_recounts(%Receipt{} = receipt) do
    Enum.filter(receipt.lines, &ReceiptLine.diverged_after_recounts?/1)
  end

  defp maybe_post(multi, _name, [], _attrs), do: multi

  defp maybe_post(multi, name, entries, attrs) do
    Multi.run(multi, name, fn _repo, _changes ->
      Inventory.post_transaction(Map.put(attrs, :entries, entries))
    end)
  end

  # Put away first, then correct, so the correction lands where the goods are.
  # Both passes reconcile per *lot*, never per line: suppliers split one item
  # across two lines (same lot), and independent reconciliation would move the
  # balance twice and subtract each line's goods from the other.
  defp boxing_entries(lines, receipt) do
    lines
    |> lot_groups()
    |> Enum.flat_map(fn group ->
      group
      |> boxing_moves(receipt)
      |> Enum.flat_map(fn {box_id, moved} ->
        [
          %{
            lot_id: group.lot_id,
            location_id: receipt.location_id,
            quantity: Decimal.negate(moved)
          },
          %{
            lot_id: group.lot_id,
            location_id: receipt.location_id,
            box_id: box_id,
            quantity: moved
          }
        ]
      end)
    end)
  end

  # Reconcile against the ledger *now*, not the invoice: they differ on a
  # recount, and only the ledger balance can be corrected. The invoice figure
  # stays as `expected_quantity` for the divergence report to the supplier.
  defp correction_entries(lines, receipt) do
    lines
    |> lot_groups()
    |> Enum.flat_map(&lot_corrections(&1, receipt))
  end

  defp lot_corrections(group, receipt) do
    moves = group |> boxing_moves(receipt) |> Map.new()
    moved_total = moves |> Map.values() |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    loose_after = Decimal.sub(unboxed_quantity(group.lot_id, receipt), moved_total)

    group.counted_by_box
    |> Enum.sort()
    |> Enum.map(fn {box_id, counted} ->
      current =
        case box_id do
          nil ->
            loose_after

          box_id ->
            Decimal.add(
              boxed_quantity(group.lot_id, box_id, receipt),
              Map.get(moves, box_id, Decimal.new(0))
            )
        end

      difference = Decimal.sub(counted, current)

      if Decimal.equal?(difference, 0) do
        nil
      else
        %{
          lot_id: group.lot_id,
          location_id: receipt.location_id,
          box_id: box_id,
          quantity: difference
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # One reconciliation unit: a lot, counts summed per box (nil box is loose).
  # Sorted for a stable entry order.
  defp lot_groups(lines) do
    lines
    |> Enum.group_by(&lot_id/1)
    |> Enum.sort()
    |> Enum.map(fn {lot_id, lot_lines} ->
      %{
        lot_id: lot_id,
        counted_by_box:
          lot_lines
          |> Enum.group_by(& &1.box_id, & &1.counted_quantity)
          |> Map.new(fn {box_id, counts} -> {box_id, Enum.reduce(counts, &Decimal.add/2)} end)
      }
    end)
  end

  # What the lines counted loose stays loose; the rest is put away, each box's
  # shortfall first and any remainder into the last box.
  defp boxing_moves(group, receipt) do
    boxes = group.counted_by_box |> Map.delete(nil) |> Map.keys() |> Enum.sort()

    if boxes == [] do
      []
    else
      counted_loose = Map.get(group.counted_by_box, nil, Decimal.new(0))

      to_box =
        Decimal.max(
          Decimal.sub(unboxed_quantity(group.lot_id, receipt), counted_loose),
          Decimal.new(0)
        )

      {moves, remainder} =
        Enum.map_reduce(boxes, to_box, fn box_id, remaining ->
          shortfall =
            Decimal.max(
              Decimal.sub(
                Map.fetch!(group.counted_by_box, box_id),
                boxed_quantity(group.lot_id, box_id, receipt)
              ),
              Decimal.new(0)
            )

          take = Decimal.min(remaining, shortfall)
          {{box_id, take}, Decimal.sub(remaining, take)}
        end)

      moves
      |> add_remainder_to_last(remainder)
      |> Enum.reject(fn {_box_id, moved} -> Decimal.compare(moved, 0) != :gt end)
    end
  end

  defp add_remainder_to_last(moves, remainder) do
    if Decimal.compare(remainder, 0) == :gt do
      List.update_at(moves, -1, fn {box_id, moved} -> {box_id, Decimal.add(moved, remainder)} end)
    else
      moves
    end
  end

  defp unboxed_quantity(lot_id, receipt) do
    Inventory.balance(lot_id: lot_id, location_id: receipt.location_id, box_id: nil)
  end

  defp boxed_quantity(lot_id, box_id, receipt) do
    Inventory.balance(lot_id: lot_id, location_id: receipt.location_id, box_id: box_id)
  end

  defp lot_id(line) do
    item = line.invoice_item

    Repo.one!(
      from l in EstoqueOS.Inventory.Lot,
        where: l.product_id == ^item.product_id,
        where:
          fragment("? is not distinct from ?", l.lot_number, type(^item.lot_number, :string)),
        select: l.id
    )
  end

  defp verify_boxes(lines) do
    now = DateTime.utc_now(:second)

    ids = lines |> Enum.map(& &1.box_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {count, _} =
      Box
      |> where([b], b.id in ^ids)
      |> Repo.update_all(set: [last_verified_at: now, updated_at: now])

    {:ok, count}
  end
end
