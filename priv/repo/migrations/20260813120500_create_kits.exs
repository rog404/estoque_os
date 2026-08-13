defmodule EstoqueOS.Repo.Migrations.CreateKits do
  @moduledoc """
  A kit, its recipe, and where a kit lot's components actually came from.

  A kit is a product now: assembling one converts component lots into a lot of
  the kit's own product, and no screen needs to know a kit exists to write one
  off. `products.kit_id` is what says so, and it is added from here rather than
  from `CreateCatalog` because the kit is the newer of the two ideas — the
  catalog stands on its own without it.

  `kit_items` names what a kit is made of. Kit sheets name items in free text
  that does not always match the catalog; the raw description is kept so
  unresolved lines stay visible rather than silently dropped.

  What "a kit is a product" would cost — knowing which component lots went into
  a given kit lot, for a recall — is what `kit_lot_provenances` buys back: one
  row per (kit lot, component lot) pair, however many distinct component lots a
  batch of assembly drew from.
  """

  use Ecto.Migration

  def change do
    create table(:kits) do
      add :name, :string, null: false
      add :description, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:kits, ["lower(name)"], name: :kits_lower_name_index)

    alter table(:products) do
      add :kit_id, references(:kits, on_delete: :restrict)
    end

    create unique_index(:products, [:kit_id])

    create table(:kit_items) do
      add :kit_id, references(:kits, on_delete: :delete_all), null: false
      add :product_id, references(:products, on_delete: :restrict)
      add :description, :string, null: false
      add :quantity, :decimal, precision: 16, scale: 4, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:kit_items, [:kit_id])
    create index(:kit_items, [:product_id])

    create constraint(:kit_items, :kit_items_quantity_must_be_positive, check: "quantity > 0")

    create table(:kit_lot_provenances) do
      add :kit_lot_id, references(:lots, on_delete: :restrict), null: false
      add :component_lot_id, references(:lots, on_delete: :restrict), null: false
      add :quantity, :decimal, precision: 16, scale: 4, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:kit_lot_provenances, [:kit_lot_id])
    create index(:kit_lot_provenances, [:component_lot_id])

    create constraint(:kit_lot_provenances, :kit_lot_provenances_quantity_must_be_positive,
             check: "quantity > 0"
           )
  end
end
