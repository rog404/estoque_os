defmodule EstoqueOS.Inventory.Lot do
  @moduledoc """
  A batch of a product with its own manufacturing and expiry dates.

  Every ledger entry points at a lot. When an invoice carries no lot data at
  all, a single placeholder lot (`lot_number: nil`) is created per product and
  flagged for review instead of silently inventing a number.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.Product

  schema "lots" do
    field :lot_number, :string
    field :manufactured_on, :date
    field :expires_on, :date
    field :needs_review, :boolean, default: false

    belongs_to :product, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:lot_number, :manufactured_on, :expires_on, :needs_review, :product_id])
    |> update_change(:lot_number, &normalize_lot_number/1)
    |> validate_required([:product_id])
    |> validate_dates()
    |> assoc_constraint(:product)
    |> unique_constraint([:product_id, :lot_number])
    |> check_constraint(:manufactured_on, name: :lots_manufactured_before_expiry)
  end

  @doc "True when the lot is a placeholder for unknown lot data."
  def unknown?(%__MODULE__{lot_number: nil}), do: true
  def unknown?(%__MODULE__{}), do: false

  defp normalize_lot_number(nil), do: nil

  defp normalize_lot_number(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_dates(changeset) do
    manufactured_on = get_field(changeset, :manufactured_on)
    expires_on = get_field(changeset, :expires_on)

    if manufactured_on && expires_on && Date.after?(manufactured_on, expires_on) do
      add_error(changeset, :expires_on, "must be on or after the manufacturing date")
    else
      changeset
    end
  end
end
