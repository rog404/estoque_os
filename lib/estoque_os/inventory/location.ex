defmodule EstoqueOS.Inventory.Location do
  @moduledoc """
  A node in the physical tree: warehouses, mission sites and the special
  `transit` location that mirrors "estoque em trânsito" in the accounting.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.Box

  @kinds ~w(warehouse mission_site transit other)

  @doc "Known location kinds."
  def kinds, do: @kinds

  schema "locations" do
    field :name, :string
    field :kind, :string
    field :notes, :string
    field :active, :boolean, default: true

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :boxes, Box

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(location, attrs) do
    location
    |> cast(attrs, [:name, :kind, :notes, :active, :parent_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:parent)
    |> unique_constraint(:name, name: :locations_lower_name_index)
    |> check_constraint(:kind, name: :locations_kind_must_be_known)
  end
end
