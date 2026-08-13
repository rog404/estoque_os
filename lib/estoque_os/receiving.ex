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

  @doc "Lines nobody has counted yet."
  def uncounted_lines(%Receipt{} = receipt) do
    Enum.filter(receipt.lines, &is_nil(&1.counted_quantity))
  end

  ## Counting

  @doc """
  Records the count and the box for one line.
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
  """
  def uncount_line(%ReceiptLine{} = line) do
    line
    |> ReceiptLine.changeset(%{counted_quantity: nil})
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
