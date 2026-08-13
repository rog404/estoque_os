defmodule EstoqueOS.Receiving.ReceiptLine do
  @moduledoc """
  One invoice line as the warehouse actually found it: how many arrived and
  which box they went into.

  `counted_quantity` stays nil until someone counts — nil means "not counted
  yet", which is not the same as "counted zero", and the two must never be
  confused when a divergence report goes to the supplier.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.Box
  alias EstoqueOS.Invoices.InvoiceItem
  alias EstoqueOS.Receiving.Receipt

  schema "receipt_lines" do
    field :expected_quantity, :decimal
    field :counted_quantity, :decimal
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
end
