defmodule EstoqueOS.Repo.Migrations.CreateProductAliases do
  use Ecto.Migration

  def change do
    create table(:product_aliases) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # Upper-cased, accent-stripped, punctuation-collapsed: two spellings of one
      # name normalize to the same string, which is what search and dedup match on.
      add :normalized, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:product_aliases, [:product_id])
    # One normalized name points at one product: the guard against two products
    # claiming the same alias, and the key search matches on.
    create unique_index(:product_aliases, [:normalized])
  end
end
