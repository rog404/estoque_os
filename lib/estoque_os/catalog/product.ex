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

  @segments ~w(medical marketing)

  schema "products" do
    field :name, :string
    field :segment, :string, default: "medical"
    field :ncm, :string
    field :stock_unit, :string, default: "UN"
    field :controlled, :boolean, default: false
    # Whether a lot arriving with no expiry is normal or worth an alarm.
    field :expiry_expected, :boolean, default: true

    # Same question for the lot number: a donated blanket has none, and flagging it buries real cases.
    field :lot_expected, :boolean, default: true
    field :min_stock_override, :decimal
    field :expiry_alert_days_override, :integer
    field :classification, :string
    field :sector, :string
    field :notes, :string
    field :active, :boolean, default: true

    belongs_to :product_group, ProductGroup
    # Set once by `Kits.create_kit/1`, never via a product form; lets a kit be
    # issued, searched and reported like any product.
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
      :segment,
      :product_group_id,
      :kit_id,
      :ncm,
      :stock_unit,
      :controlled,
      :expiry_expected,
      :lot_expected,
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
    |> validate_required([:name, :stock_unit, :segment])
    |> validate_inclusion(:segment, @segments)
    |> validate_format(:ncm, ~r/^\d{8}$/)
    |> validate_number(:min_stock_override, greater_than_or_equal_to: 0)
    |> validate_number(:expiry_alert_days_override, greater_than: 0)
    |> assoc_constraint(:product_group)
    |> assoc_constraint(:kit)
    |> unique_constraint(:name, name: :products_lower_name_index)
    |> check_constraint(:ncm, name: :products_ncm_must_have_8_digits)
    |> check_constraint(:segment, name: :products_segment_must_be_known)
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

  @doc """
  The two stocks this system holds.

    * `medical` — what a surgical mission consumes and donates. The default.
    * `marketing` — material the ONG *sells* (shirts, banners).

  A closed list on purpose: the marketing role's default view filters on it, and
  a hand-typed typo would show the wrong stock.
  """
  def segments, do: @segments

  @stock_units ~w(UN CX FR PT PC AMP KIT PAR ROL)

  @doc """
  The units this operation counts things in.

  Offered as a list, not typed, so `UN`, `Un` and `unidade` do not coexist
  (SPEC §3.13). Not closed in the database: `normalize_unit/1` still accepts any
  unit an NF-e brings, since refusing it would block a delivery over a label.
  """
  def stock_units, do: @stock_units
end
