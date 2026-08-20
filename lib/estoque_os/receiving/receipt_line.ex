defmodule EstoqueOS.Receiving.ReceiptLine do
  @moduledoc """
  One invoice line as the warehouse actually found it: how many arrived and
  which box they went into.

  `counted_quantity` stays nil until someone counts — nil means "not counted
  yet", which is not the same as "counted zero", and the two must never be
  confused when a divergence report goes to the supplier.

  `count_attempts` is every count anyone made of this line, oldest first, and
  `counted_quantity` is the one that was finally believed. A line whose first
  count disagrees with the invoice is not booked: it is counted again, blind,
  and the trail of what was typed each time stays here. Three disagreeing
  counts stop being a miscount and become something the manager is shown.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.Box
  alias EstoqueOS.Invoices.InvoiceItem
  alias EstoqueOS.Receiving.Receipt

  schema "receipt_lines" do
    field :expected_quantity, :decimal
    field :counted_quantity, :decimal
    field :count_attempts, {:array, :decimal}, default: []
    field :notes, :string

    belongs_to :receipt, Receipt
    belongs_to :invoice_item, InvoiceItem
    belongs_to :box, Box

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(line, attrs) do
    line
    |> cast(attrs, [
      :expected_quantity,
      :counted_quantity,
      :count_attempts,
      :notes,
      :invoice_item_id,
      :box_id
    ])
    |> validate_required([:expected_quantity, :invoice_item_id])
    |> validate_number(:counted_quantity, greater_than_or_equal_to: 0)
    |> assoc_constraint(:receipt)
    |> assoc_constraint(:invoice_item)
    |> assoc_constraint(:box)
    |> unique_constraint([:receipt_id, :invoice_item_id])
    |> check_constraint(:counted_quantity,
      name: :receipt_lines_counted_must_not_be_negative
    )
  end

  @doc """
  How far the count is from the invoice, or nil while nobody has counted.
  """
  def divergence(%__MODULE__{counted_quantity: nil}), do: nil

  def divergence(%__MODULE__{} = line) do
    Decimal.sub(line.counted_quantity, line.expected_quantity)
  end

  @doc "True when the line was counted and disagrees with the invoice."
  def diverges?(%__MODULE__{} = line) do
    case divergence(line) do
      nil -> false
      difference -> not Decimal.equal?(difference, 0)
    end
  end

  @doc """
  How many counts of this line have been made.
  """
  def attempts(%__MODULE__{count_attempts: attempts}), do: length(attempts || [])

  @doc """
  True when somebody counted this line and the number was not accepted, so it
  is waiting to be counted again.

  The state the screen has to render, and the reason it cannot be derived from
  `counted_quantity` alone: nil there means either "nobody counted" or "counted
  and we are asking again", and those two rows say completely different things
  to the operator standing in front of them.
  """
  def awaiting_recount?(%__MODULE__{counted_quantity: nil} = line), do: attempts(line) > 0
  def awaiting_recount?(%__MODULE__{}), do: false

  @doc """
  True when this line was counted more than once and *still* disagrees with the
  invoice.

  Not a miscount any more. Either goods did not arrive or the invoice is wrong,
  and both are somebody else's decision — see the manager's overview.
  """
  def diverged_after_recounts?(%__MODULE__{} = line) do
    attempts(line) > 1 and diverges?(line)
  end
end
