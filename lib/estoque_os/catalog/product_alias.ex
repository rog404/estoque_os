defmodule EstoqueOS.Catalog.ProductAlias do
  @moduledoc """
  Another name the same product goes by: a nickname, a former catalogue name, a
  supplier's wording. Search matches it, so "equipo" finds the macrodrip set and
  a renamed product still answers to its old name.

  `normalized` is the form two spellings of one name share; a unique index on it
  keeps one normalized name pointing at a single product.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.Product

  schema "product_aliases" do
    field :name, :string
    field :normalized, :string

    belongs_to :product, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(product_alias, attrs) do
    product_alias
    |> cast(attrs, [:name, :product_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :product_id])
    |> put_normalized()
    |> validate_required([:normalized])
    |> assoc_constraint(:product)
    |> unique_constraint(:normalized)
  end

  defp put_normalized(changeset) do
    case get_field(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :normalized, normalize(name))
    end
  end

  @doc "Lower-case, accent-stripped, single-spaced: what matching compares."
  def normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/\s+/u, " ")
  end
end
