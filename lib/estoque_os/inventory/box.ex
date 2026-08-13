defmodule EstoqueOS.Inventory.Box do
  @moduledoc """
  A movable container (AN01, JP04...) that lives at a location.

  Moving a box moves its *presumed* contents: `last_verified_at` records when
  those contents were last actually counted, so balances can be shown as
  "verified on X" versus "presumed since the last move".
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EstoqueOS.Inventory.Location

  schema "boxes" do
    field :code, :string
    field :last_verified_at, :utc_datetime
    field :notes, :string
    field :active, :boolean, default: true

    belongs_to :location, Location

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(box, attrs) do
    box
    |> cast(attrs, [:code, :last_verified_at, :notes, :active, :location_id])
    |> update_change(:code, &normalize_code/1)
    |> validate_required([:code, :location_id])
    |> assoc_constraint(:location)
    |> unique_constraint(:code, name: :boxes_upper_code_index)
  end

  defp normalize_code(nil), do: nil
  defp normalize_code(value), do: value |> String.trim() |> String.upcase()
end
