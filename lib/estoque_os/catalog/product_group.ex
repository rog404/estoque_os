defmodule EstoqueOS.Catalog.ProductGroup do
  @moduledoc """
  A family of interchangeable products ("Agulhas"), used for search and for
  mapping the divergent names suppliers give to the same item.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.{Product, ProductGroupSynonym}

  schema "product_groups" do
    field :name, :string
    field :notes, :string

    has_many :synonyms, ProductGroupSynonym
    has_many :products, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(product_group, attrs) do
    product_group
    |> cast(attrs, [:name, :notes])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> unique_constraint(:name, name: :product_groups_lower_name_index)
  end
end
