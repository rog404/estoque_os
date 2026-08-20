defmodule EstoqueOS.Repo.Migrations.AddProductSegment do
  @moduledoc """
  Which stock a product belongs to.

  There is a second stock in this operation — marketing material, which is
  *sold* rather than consumed on a mission — and it shares everything the
  surgical stock has: the ledger, lots, boxes, locations, the NF-e import. What
  it does not share is who looks after it and who may see it.

  A column on the product rather than a separate location, because the question
  is what a thing *is*, not where it sits: a marketing item stored in the same
  warehouse is still marketing, and a location filter would have to be right
  about every box for the answer to be right.
  """

  use Ecto.Migration

  def change do
    alter table(:products) do
      add :segment, :string, null: false, default: "medical"
    end

    create constraint(:products, :products_segment_must_be_known,
             check: "segment IN ('medical', 'marketing')"
           )

    # Every listing the marketing role opens filters on this, so it is not an
    # afterthought index: it is the one the role's whole view depends on.
    create index(:products, [:segment])
  end
end
