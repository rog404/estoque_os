defmodule EstoqueOS.Kits.KitItem do
  @moduledoc """
  A component of a kit. The kit spreadsheets name items in free text that does
  not always match the catalog, so the raw description is kept and `product_id`
  stays null until someone resolves the line.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Kits.Kit

  schema "kit_items" do
    field :description, :string
    field :quantity, :decimal

    belongs_to :kit, Kit
    belongs_to :product, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:description, :quantity, :kit_id, :product_id])
    |> update_change(:description, &String.trim/1)
    |> validate_required([:description, :quantity])
    |> validate_number(:quantity, greater_than: 0)
    |> assoc_constraint(:kit)
    |> assoc_constraint(:product)
    |> check_constraint(:quantity, name: :kit_items_quantity_must_be_positive)
  end
end
