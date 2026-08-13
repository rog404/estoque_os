defmodule EstoqueOS.Catalog.ProductIdentifier do
  @moduledoc """
  How the outside world names a product: a GTIN (`cEAN`, globally unique) or a
  supplier code (`cProd`, unique only within that supplier).

  GTIN is the primary matcher on invoice import.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.{Product, Supplier}

  @kinds ~w(gtin supplier_code)

  @doc "Known identifier kinds."
  def kinds, do: @kinds

  schema "product_identifiers" do
    field :kind, :string
    field :value, :string

    belongs_to :product, Product
    belongs_to :supplier, Supplier

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(identifier, attrs) do
    identifier
    |> cast(attrs, [:kind, :value, :product_id, :supplier_id])
    |> update_change(:value, &String.trim/1)
    |> validate_required([:kind, :value, :product_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_gtin()
    |> validate_supplier_is_present_for_supplier_codes()
    |> assoc_constraint(:product)
    |> assoc_constraint(:supplier)
    |> unique_constraint([:kind, :value, :supplier_id])
    |> check_constraint(:kind, name: :product_identifiers_kind_must_be_known)
    |> check_constraint(:supplier_id,
      name: :product_identifiers_supplier_code_needs_supplier
    )
  end

  # NF-e uses "SEM GTIN" when the item has no barcode; such lines must not
  # create an identifier at all, so we reject them here instead of storing junk.
  defp validate_gtin(changeset) do
    if get_field(changeset, :kind) == "gtin" do
      validate_format(changeset, :value, ~r/^\d{8}$|^\d{12,14}$/)
    else
      changeset
    end
  end

  defp validate_supplier_is_present_for_supplier_codes(changeset) do
    if get_field(changeset, :kind) == "supplier_code" do
      validate_required(changeset, [:supplier_id])
    else
      changeset
    end
  end
end
