defmodule EstoqueOS.Kits.Kit do
  @moduledoc """
  A named bill of materials (Kit Paciente, Anestesia, ...) assembled for a
  mission and consumed as a unit.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Kits.KitItem

  schema "kits" do
    field :name, :string
    field :description, :string
    field :active, :boolean, default: true

    has_many :items, KitItem
    has_one :product, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(kit, attrs) do
    kit
    |> cast(attrs, [:name, :description, :active])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> cast_assoc(:items, with: &KitItem.changeset/2)
    |> unique_constraint(:name, name: :kits_lower_name_index)
  end
end
