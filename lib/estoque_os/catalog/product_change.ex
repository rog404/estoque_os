defmodule EstoqueOS.Catalog.ProductChange do
  @moduledoc """
  One edit to what the catalog *says* about a product, and who made it.

  Not the ledger. `transactions` records goods moving, and a planning figure
  posted there would appear in every movement report as an event that never
  happened. But "who lowered the minimum on the gauze, and when" is exactly the
  question asked after a mission runs short, so it gets its own small log —
  append-only, for the same reason the ledger is.

  Values are stored as strings on purpose: this table will outlive the types of
  the columns it describes, and what it needs to answer is "it went from 60 to
  20", not arithmetic.
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
