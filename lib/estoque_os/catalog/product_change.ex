defmodule EstoqueOS.Catalog.ProductChange do
  @moduledoc """
  One edit to what the catalog *says* about a product, and who made it.

  Not the ledger: a planning figure there would show as a movement that never
  happened. Its own append-only log answers "who lowered the minimum, and when".

  Values are strings on purpose: the table outlives the column types it describes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "product_changes" do
    field :field, :string
    field :from_value, :string
    field :to_value, :string

    belongs_to :product, EstoqueOS.Catalog.Product
    belongs_to :user, EstoqueOS.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [:product_id, :user_id, :field, :from_value, :to_value])
    |> validate_required([:product_id, :field])
  end
end
