defmodule EstoqueOS.Catalog.UnitConversion do
  @moduledoc """
  How many stock units fit in one commercial unit ("1 CX = 250 UN").

  Confirmed once by a human on the first import of a product + unit and reused
  afterwards — this is what turns invoice prices into unit prices.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Catalog.Product

  schema "unit_conversions" do
    field :from_unit, :string
    field :factor, :decimal
    field :confirmed_at, :utc_datetime

    belongs_to :product, Product
    belongs_to :confirmed_by, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversion, attrs) do
    conversion
    |> cast(attrs, [:from_unit, :factor, :product_id, :confirmed_by_id, :confirmed_at])
    |> update_change(:from_unit, &normalize_unit/1)
    |> validate_required([:from_unit, :factor, :product_id])
    |> validate_number(:factor, greater_than: 0)
    |> assoc_constraint(:product)
    |> assoc_constraint(:confirmed_by)
    |> unique_constraint([:product_id, :from_unit])
    |> check_constraint(:factor, name: :unit_conversions_factor_must_be_positive)
  end

  defp normalize_unit(nil), do: nil
  defp normalize_unit(value), do: value |> String.trim() |> String.upcase()
end
