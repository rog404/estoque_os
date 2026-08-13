defmodule EstoqueOS.Catalog.ProductGroupSynonym do
  @moduledoc """
  An alternative name a supplier or a warehouse operator uses for a group.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.ProductGroup

  schema "product_group_synonyms" do
    field :name, :string

    belongs_to :product_group, ProductGroup

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(synonym, attrs) do
    synonym
    |> cast(attrs, [:name, :product_group_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :product_group_id])
    |> assoc_constraint(:product_group)
    |> unique_constraint(:name, name: :product_group_synonyms_lower_name_index)
  end
end
