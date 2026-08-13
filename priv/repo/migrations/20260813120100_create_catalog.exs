defmodule EstoqueOS.Repo.Migrations.CreateCatalog do
  @moduledoc """
  Who sells to the operation, what the operation stocks, and who changed it.

  `products.kit_id` is deliberately absent here even though a kit is a product:
  the column belongs to the kit, and adding it from `CreateKits` is what keeps
  this migration referring only to tables that already exist.
  """

  use Ecto.Migration

  def change do
    create table(:suppliers) do
      add :cnpj, :string, size: 14, null: false
      add :legal_name, :string, null: false
      add :trade_name, :string
      add :email, :string
      add :phone, :string
      add :city, :string
      add :state, :string, size: 2
      add :notes, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:suppliers, [:cnpj])

    create constraint(:suppliers, :suppliers_cnpj_must_have_14_digits,
             check: "cnpj ~ '^[0-9]{14}$'"
           )

    create table(:product_groups) do
      add :name, :string, null: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_groups, ["lower(name)"], name: :product_groups_lower_name_index)

    # Supplier nomenclature varies wildly for the same item ("agulha" vs
    # "Sterecam"); synonyms feed search and import matching.
    create table(:product_group_synonyms) do
      add :product_group_id, references(:product_groups, on_delete: :delete_all), null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_group_synonyms, ["lower(name)"],
             name: :product_group_synonyms_lower_name_index
           )

    create index(:product_group_synonyms, [:product_group_id])

    create table(:products) do
      add :name, :string, null: false
      add :product_group_id, references(:product_groups, on_delete: :nilify_all)
      add :ncm, :string, size: 8
      # Unit the stock is kept in — always the individual unit, never the
      # commercial packaging the supplier invoices in.
      add :stock_unit, :string, null: false, default: "UN"
      add :controlled, :boolean, null: false, default: false
      add :min_stock_override, :decimal, precision: 16, scale: 4
      add :expiry_alert_days_override, :integer
      # Catalog metadata carried over from the OSI standard supply table.
      add :classification, :string
      add :sector, :string
      add :notes, :text
      add :active, :boolean, null: false, default: true
      # A lot arriving without expires_on is two different facts wearing the
      # same NULL — this says which one it is for this product. Defaults to
      # true: nearly the whole catalog is medical supply.
      add :expiry_expected, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:products, ["lower(name)"], name: :products_lower_name_index)
    create index(:products, [:product_group_id])
    create index(:products, [:ncm])

    create constraint(:products, :products_ncm_must_have_8_digits,
             check: "ncm is null or ncm ~ '^[0-9]{8}$'"
           )

    create constraint(:products, :products_min_stock_override_must_not_be_negative,
             check: "min_stock_override is null or min_stock_override >= 0"
           )

    create constraint(:products, :products_expiry_alert_days_override_must_be_positive,
             check: "expiry_alert_days_override is null or expiry_alert_days_override > 0"
           )

    # GTIN (cEAN) is the primary matcher on import; supplier codes (cProd) are
    # only unique within a supplier.
    create table(:product_identifiers) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :value, :string, null: false
      add :supplier_id, references(:suppliers, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_identifiers, [:kind, :value, :supplier_id],
             nulls_distinct: false
           )

    create index(:product_identifiers, [:product_id])

    create constraint(:product_identifiers, :product_identifiers_kind_must_be_known,
             check: "kind in ('gtin', 'supplier_code')"
           )

    # A supplier code without a supplier is meaningless.
    create constraint(:product_identifiers, :product_identifiers_supplier_code_needs_supplier,
             check: "kind <> 'supplier_code' or supplier_id is not null"
           )

    # "1 CX = 250 UN": asked once per product + commercial unit, reused after.
    create table(:unit_conversions) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :from_unit, :string, null: false
      add :factor, :decimal, precision: 16, scale: 4, null: false
      add :confirmed_by_id, references(:users, on_delete: :nilify_all)
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:unit_conversions, [:product_id, :from_unit])

    create constraint(:unit_conversions, :unit_conversions_factor_must_be_positive,
             check: "factor > 0"
           )

    # The minimum a mission carries is not goods, so it has no business in the
    # ledger: `transactions` is for things that physically moved, and a planning
    # figure posted there would show up in every movement report as an event
    # that never happened.
    #
    # It still has to be answerable for. "Who lowered the minimum on the gauze,
    # and when" is exactly the question that gets asked after a mission runs
    # short, so it gets its own small log — append-only like the ledger, and for
    # the same reason.
    create table(:product_changes) do
      add :product_id, references(:products, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :field, :string, null: false
      add :from_value, :string
      add :to_value, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:product_changes, [:product_id])
  end
end
