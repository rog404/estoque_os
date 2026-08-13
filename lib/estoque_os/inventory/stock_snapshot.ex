defmodule EstoqueOS.Inventory.StockSnapshot do
  @moduledoc """
  Materialized balance per lot + box + location.

  A cache, never a source of truth: it is refreshed inside the same database
  transaction that appends the entries, and `EstoqueOS.Inventory` can always
  recompute the same numbers straight from `transaction_entries`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.{Box, Location, Lot}

  schema "stock_snapshots" do
    field :quantity, :decimal, default: Decimal.new(0)

    belongs_to :lot, Lot
    belongs_to :box, Box
    belongs_to :location, Location

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:quantity, :lot_id, :box_id, :location_id])
    |> validate_required([:quantity, :lot_id, :location_id])
    |> assoc_constraint(:lot)
    |> assoc_constraint(:box)
    |> assoc_constraint(:location)
    |> unique_constraint([:lot_id, :box_id, :location_id])
  end
end
