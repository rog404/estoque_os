defmodule EstoqueOS.Inventory.TransactionEntry do
  @moduledoc """
  A signed quantity of one lot moving in or out of a location (and optionally
  a box), with the unit cost snapshotted at the time of the movement.

  A null `unit_cost` means "value not informed" — the case for donations. It is
  never a symbolic cent: 0.01 poisons average cost and stock value reports.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.{Box, Location, Lot, Transaction}

  schema "transaction_entries" do
    field :quantity, :decimal
    field :unit_cost, :decimal
    # What the buyer paid, when this line was a sale. A different question from
    # `unit_cost`, which is what the ONG paid — average cost and stock value are
    # both derived from that one, so a sale price living in it would quietly
    # rewrite the value of everything.
    field :sale_unit_price, :decimal

    belongs_to :transaction, Transaction
    belongs_to :lot, Lot
    belongs_to :box, Box
    belongs_to :location, Location

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:quantity, :unit_cost, :sale_unit_price, :lot_id, :box_id, :location_id])
    |> validate_required([:quantity, :lot_id, :location_id])
    |> validate_quantity_is_not_zero()
    |> validate_number(:unit_cost, greater_than: 0)
    |> assoc_constraint(:lot)
    |> assoc_constraint(:box)
    |> assoc_constraint(:location)
    |> check_constraint(:quantity, name: :transaction_entries_quantity_must_not_be_zero)
    |> check_constraint(:unit_cost, name: :transaction_entries_unit_cost_must_be_positive)
  end

  defp validate_quantity_is_not_zero(changeset) do
    case get_field(changeset, :quantity) do
      nil -> changeset
      quantity -> if Decimal.equal?(quantity, 0), do: add_zero_error(changeset), else: changeset
    end
  end

  defp add_zero_error(changeset), do: add_error(changeset, :quantity, "must not be zero")
end
