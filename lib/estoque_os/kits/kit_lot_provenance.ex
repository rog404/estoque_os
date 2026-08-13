defmodule EstoqueOS.Kits.KitLotProvenance do
  @moduledoc """
  One component lot that went into one kit lot, and how much of it.

  A kit lot's row in `lots` says nothing about what it is made of — same as
  every other product, its identity is the recipe (`kit_items`), not the
  batch. This is what a recall reads: given a component lot, which kit lots
  drew from it, so the kits built from a bad batch can be found without
  opening every box on the shelf.
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
