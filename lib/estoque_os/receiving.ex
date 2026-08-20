defmodule EstoqueOS.Receiving do
  @moduledoc """
  Checking what physically arrived against what the invoice promised.

  Posting an invoice books the quantities the supplier says they sent. The
  conference is what turns that promise into a fact: each line is counted, the
  difference is posted as an adjustment with a reason, and the goods are put
  into a box — which is when a balance stops being presumed and becomes
  verified.

  Counting is allowed to be partial. In a mission storage room a full audit is
  fiction, so lines nobody counted stay untouched rather than being recorded
  as zero.
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

  Only a posted invoice can be conferred: before that there is nothing in
  stock to disagree with. A second round is allowed — the warehouse recounts
  when a divergence smells like a miscount.
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

  ## Reading

  def get_receipt!(id), do: Receipt |> Repo.get!(id) |> load_receipt()

  def get_open_receipt(%Invoice{} = invoice) do
    case open_receipt(invoice) do
      nil -> nil
      receipt -> load_receipt(receipt)
    end
  end

  @doc """
  Deliveries still waiting to be checked, newest invoice first.

  The list the operator starts their day from. Until this existed the only way
  into a conference was the invoice screen, which sits behind the money gate —
  so the person whose job this is could not reach it.

  A row is either a round somebody has open, with how far it got, or a posted
  invoice nobody has begun. An invoice whose conference is closed drops off:
  a recount is a deliberate act, started from the invoice by someone who read
  the divergence.

  Deliberately carries no amounts. This is read by the role that must not see
  them, and the safest number to hide is the one never sent.
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

  # Lines come back in a fixed order. Without the `order_by` Postgres returns
  # them however the plan happened to produce them, so recording one line could
  # reshuffle the rest — the operator typed into row four and watched it move.
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

  Deliberately not "lines with no count of record". A line whose first count
  disagreed with the invoice has no count of record either, and lumping the two
  together made a four-line invoice report "4 not counted" and "1 to count
  again" side by side — five jobs on four lines. They are different jobs: one
  has not been visited, the other has been visited and is waiting for somebody
  to go back to the shelf. See `awaiting_recount_lines/1`.
  """
  def uncounted_lines(%Receipt{} = receipt) do
    Enum.filter(receipt.lines, &(is_nil(&1.counted_quantity) and ReceiptLine.attempts(&1) == 0))
  end

  @doc "Lines counted once already and waiting to be counted again."
  def awaiting_recount_lines(%Receipt{} = receipt) do
    Enum.filter(receipt.lines, &ReceiptLine.awaiting_recount?/1)
  end

  ## Counting

  @doc """
  How many times one line is counted before a number that disagrees with the
  invoice is believed.

  Three, decided with Rogerio on 2026-08-20. The first disagreement is far more
  often a miscount than a loss, and the cheapest moment to tell them apart is
  while the operator is still holding the box. The second disagreement could
  still be the same miscount repeated — the eye that read "27" once reads it
  again. By the third the number is the number.
  """
  def counts_required, do: 3

  @doc """
  Records one count of a line, and decides whether to believe it.

  This is the rule the conference was missing. It used to take whatever was
  typed and book it, so the logistics operator could record any quantity at all
  against an invoice that said something else — the exact hole
  `AuditLive.Count` was built to close for box counts, still open here.

  Returns:

    * `{:recorded, line}` — the count agreed with the invoice, or it is the
      last count we are going to ask for. `counted_quantity` is set.
    * `{:recount, line}` — the count disagreed and there are counts left.
      Nothing is booked; the trail is kept and the line goes back to asking.
    * `{:error, reason}`.

  The box is written either way. The operator put the goods somewhere, and that
  is true regardless of how the arithmetic turns out.

  Nothing here reaches the ledger — a conference writes when it closes — so a
  count that is not believed costs an edit to a working document, not an
  adjustment filed forever.
  """
  def record_count(%ReceiptLine{} = line, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    case to_decimal(attrs["counted_quantity"]) do
      nil ->
        {:error, :invalid_quantity}

      # Checked here rather than left to the changeset. A negative count is not
      # a divergence to be recounted, it is a typo, and storing it as an attempt
      # would spend one of the three counts on a number that cannot be a count:
      # `counted_quantity` is only written on the last attempt, so the column
      # constraint that refuses it would not have been reached until then.
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

  A separate function and not `update_line(line, %{counted_quantity: nil})`,
  because `normalize/1` drops a nil count on purpose: an empty field on a form
  that saves four values at once means "I did not touch this", never "the count
  I recorded is wrong". Clearing has to be asked for in as many words.

  Nothing has reached the ledger at this point — a conference writes when it
  closes — so this is an edit to a working document and not an adjustment. The
  box is kept: the operator mistyped a quantity, not the shelf they put it on.

  The counts already made are dropped with it. Keeping them would let the next
  single count land as the third attempt and be believed on the spot, which is
  the rule in `record_count/2` deleting itself.
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

  ## Completing

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
        # What raises this on the manager's overview. A line counted three times
        # that still disagrees with the invoice is either goods that never
        # arrived or an invoice that is wrong, and neither is the operator's to
        # close alone. Same flag the box count uses, so there is one list of
        # counts somebody has to look at rather than two.
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

  Read by the conference screen, to say so on the line, and by the manager's
  overview through the transaction flagged at the close.
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

  # Put away first, then correct: the correction has to land where the goods
  # actually are, or a recount would fix the wrong position.
  defp boxing_entries(lines, receipt) do
    lines
    |> Enum.filter(& &1.box_id)
    |> Enum.flat_map(fn line ->
      unboxed = unboxed_quantity(line, receipt)

      if Decimal.compare(unboxed, 0) == :gt do
        [
          %{
            lot_id: lot_id(line),
            location_id: receipt.location_id,
            quantity: Decimal.negate(unboxed)
          },
          %{
            lot_id: lot_id(line),
            location_id: receipt.location_id,
            box_id: line.box_id,
            quantity: unboxed
          }
        ]
      else
        []
      end
    end)
  end

  # The count is reconciled against what the ledger believes *right now*, not
  # against the invoice. On a first round the two coincide; on a recount they
  # do not, and only the ledger balance can be corrected into agreement with
  # what the warehouse just counted. The invoice figure stays on the line as
  # `expected_quantity` — that is what the divergence report tells the supplier.
  defp correction_entries(lines, receipt) do
    lines
    |> Enum.map(fn line ->
      difference = Decimal.sub(line.counted_quantity, current_quantity(line, receipt))

      if Decimal.equal?(difference, 0) do
        nil
      else
        %{
          lot_id: lot_id(line),
          location_id: receipt.location_id,
          box_id: line.box_id,
          quantity: difference
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Everything the ledger holds for this lot at this location, in the box the
  # line names plus whatever is still waiting to be put away.
  defp current_quantity(line, receipt) do
    Decimal.add(unboxed_quantity(line, receipt), boxed_quantity(line, receipt))
  end

  defp unboxed_quantity(line, receipt) do
    Inventory.balance(lot_id: lot_id(line), location_id: receipt.location_id, box_id: nil)
  end

  defp boxed_quantity(%{box_id: nil}, _receipt), do: Decimal.new(0)

  defp boxed_quantity(line, receipt) do
    Inventory.balance(
      lot_id: lot_id(line),
      location_id: receipt.location_id,
      box_id: line.box_id
    )
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
