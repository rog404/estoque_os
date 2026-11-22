defmodule EstoqueOS.Kits.KitLotProvenance do
  @moduledoc """
  One component lot that went into one kit lot, and how much of it.

  What a recall reads: given a component lot, which kit lots drew from it, so
  kits from a bad batch are found without opening every box.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.Lot

  schema "kit_lot_provenances" do
    field :quantity, :decimal

    belongs_to :kit_lot, Lot
    belongs_to :component_lot, Lot

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provenance, attrs) do
    provenance
    |> cast(attrs, [:quantity, :kit_lot_id, :component_lot_id])
    |> validate_required([:quantity, :kit_lot_id, :component_lot_id])
    |> validate_number(:quantity, greater_than: 0)
    |> assoc_constraint(:kit_lot)
    |> assoc_constraint(:component_lot)
    |> check_constraint(:quantity, name: :kit_lot_provenances_quantity_must_be_positive)
  end
end
