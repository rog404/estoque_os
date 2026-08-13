defmodule EstoqueOS.Catalog.Product do
  @moduledoc """
  A catalog item, always counted in individual units regardless of the
  commercial packaging suppliers invoice it in.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.{ProductGroup, ProductIdentifier, UnitConversion}
  alias EstoqueOS.Inventory.Lot
  alias EstoqueOS.Kits.Kit

  schema "products" do
    field :name, :string
    field :ncm, :string
    field :stock_unit, :string, default: "UN"
    field :controlled, :boolean, default: false
    # Whether a lot arriving with no expiry is normal or worth an alarm.
    field :expiry_expected, :boolean, default: true
    field :min_stock_override, :decimal
    field :expiry_alert_days_override, :integer
    field :classification, :string
    field :sector, :string
    field :notes, :string
    field :active, :boolean, default: true

    belongs_to :product_group, ProductGroup
    # Set once, by `Kits.create_kit/1`, never through a product form: this is
    # what lets a kit be issued, searched and reported on exactly like any
    # other product, rather than needing its own screen for every one of
    # those.
    belongs_to :kit, Kit

    has_many :identifiers, ProductIdentifier
    has_many :unit_conversions, UnitConversion
    has_many :lots, Lot

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :product_group_id,
      :kit_id,
      :ncm,
      :stock_unit,
      :controlled,
      :expiry_expected,
      :min_stock_override,
      :expiry_alert_days_override,
      :classification,
      :sector,
      :notes,
      :active
    ])
    |> update_change(:name, &String.trim/1)
    |> update_change(:ncm, &normalize_ncm/1)
    |> update_change(:stock_unit, &normalize_unit/1)
    |> validate_required([:name, :stock_unit])
    |> validate_format(:ncm, ~r/^\d{8}$/)
    |> validate_number(:min_stock_override, greater_than_or_equal_to: 0)
    |> validate_number(:expiry_alert_days_override, greater_than: 0)
    |> assoc_constraint(:product_group)
    |> assoc_constraint(:kit)
    |> unique_constraint(:name, name: :products_lower_name_index)
    |> check_constraint(:ncm, name: :products_ncm_must_have_8_digits)
  end

  defp normalize_ncm(nil), do: nil

  defp normalize_ncm(value) do
    case String.replace(value, ~r/\D/, "") do
      "" -> nil
      digits -> digits
    end
  end

  defp normalize_unit(nil), do: nil
  defp normalize_unit(value), do: value |> String.trim() |> String.upcase()

  @stock_units ~w(UN CX FR PT PC AMP KIT PAR ROL)

  @doc """
  The units this operation counts things in.

  Offered as a list rather than typed, because a text field is how one product
  arrives as `UN`, another as `Un`, a third as `UND` and a fourth as `unidade` —
  the naming chaos SPEC §3.13 blames for killing a previous SAP attempt, arriving
  through the back door of a form nobody thought was important.

  These are the units that turn up in the real invoices in `samples/` plus the
  handful the warehouse uses by hand. It is not a closed set in the database:
  `normalize_unit/1` still accepts anything an NF-e brings in, because refusing
  a supplier's unit at import time would block a delivery over a label.
  """
  def stock_units, do: @stock_units
end
