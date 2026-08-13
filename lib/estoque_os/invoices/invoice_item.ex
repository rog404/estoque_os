defmodule EstoqueOS.Invoices.InvoiceItem do
  @moduledoc """
  One parsed NF-e line, kept verbatim for auditing, plus how it was resolved
  against our catalog.

  `lot_source` records where the lot data came from — the structured `rastro`
  group, a regex over `infAdProd`, a human typing it in, or nowhere at all.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Invoices.Invoice

  @lot_sources ~w(rastro inf_ad_prod manual none)

  @doc "Where the lot and expiry data on a line came from."
  def lot_sources, do: @lot_sources

  schema "invoice_items" do
    field :item_number, :integer
    field :supplier_product_code, :string
    field :gtin, :string
    field :description, :string
    field :ncm, :string
    field :anvisa_code, :string
    field :commercial_unit, :string
    field :commercial_quantity, :decimal
    field :commercial_unit_value, :decimal
    field :total_value, :decimal
    field :additional_info, :string

    field :lot_number, :string
    field :manufactured_on, :date
    field :expires_on, :date
    field :lot_source, :string, default: "none"

    field :conversion_factor, :decimal
    field :unit_cost, :decimal
    field :needs_review, :boolean, default: false
    field :review_notes, :string

    belongs_to :invoice, Invoice
    belongs_to :product, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :item_number,
      :supplier_product_code,
      :gtin,
      :description,
      :ncm,
      :anvisa_code,
      :commercial_unit,
      :commercial_quantity,
      :commercial_unit_value,
      :total_value,
      :additional_info,
      :lot_number,
      :manufactured_on,
      :expires_on,
      :lot_source,
      :conversion_factor,
      :unit_cost,
      :needs_review,
      :review_notes,
      :invoice_id,
      :product_id
    ])
    |> validate_required([
      :item_number,
      :description,
      :commercial_unit,
      :commercial_quantity,
      :commercial_unit_value
    ])
    |> validate_number(:commercial_quantity, greater_than: 0)
    |> validate_number(:conversion_factor, greater_than: 0)
    |> validate_inclusion(:lot_source, @lot_sources)
    |> assoc_constraint(:invoice)
    |> assoc_constraint(:product)
    |> unique_constraint([:invoice_id, :item_number])
    |> check_constraint(:lot_source, name: :invoice_items_lot_source_must_be_known)
    |> check_constraint(:commercial_quantity,
      name: :invoice_items_quantity_must_be_positive
    )
    |> check_constraint(:conversion_factor,
      name: :invoice_items_conversion_factor_must_be_positive
    )
  end
end
