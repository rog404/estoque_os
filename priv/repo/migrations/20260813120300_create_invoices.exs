defmodule EstoqueOS.Repo.Migrations.CreateInvoices do
  @moduledoc """
  The NF-e as it arrived, the events attached to it, and what each line became.

  The ledger is older than this table, so `transactions.invoice_id` is added
  from here rather than declared there: a movement that came in on an invoice
  points at it, and this is the migration that knows the invoice exists.
  """

  use Ecto.Migration

  def change do
    create table(:invoices) do
      add :supplier_id, references(:suppliers, on_delete: :restrict), null: false
      # 44-digit NF-e access key: the natural idempotency key for imports.
      add :access_key, :string, size: 44, null: false
      add :number, :string, null: false
      add :series, :string
      add :issued_on, :date, null: false
      add :total, :decimal, precision: 14, scale: 2
      add :raw_xml, :text, null: false
      add :status, :string, null: false, default: "parsed"
      add :imported_by_id, references(:users, on_delete: :nilify_all)
      add :posted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoices, [:access_key])
    create index(:invoices, [:supplier_id])

    create constraint(:invoices, :invoices_access_key_must_have_44_digits,
             check: "access_key ~ '^[0-9]{44}$'"
           )

    create constraint(:invoices, :invoices_status_must_be_known,
             check: "status in ('parsed', 'matched', 'posted', 'cancelled')"
           )

    # CC-e (correction letters) and other events are stored and attached to
    # the invoice by access key; no field-level reprocessing in the MVP.
    create table(:invoice_events) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :sequence, :integer
      add :occurred_at, :utc_datetime
      add :description, :text
      add :raw_xml, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:invoice_events, [:invoice_id])
    create unique_index(:invoice_events, [:invoice_id, :kind, :sequence])

    create constraint(:invoice_events, :invoice_events_kind_must_be_known,
             check: "kind in ('cce', 'cancellation', 'other')"
           )

    create table(:invoice_items) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :item_number, :integer, null: false

      # Raw NF-e line data, kept verbatim for auditing.
      add :supplier_product_code, :string
      add :gtin, :string
      add :description, :string, null: false
      add :ncm, :string, size: 8
      add :anvisa_code, :string
      add :commercial_unit, :string, null: false
      add :commercial_quantity, :decimal, precision: 16, scale: 4, null: false
      add :commercial_unit_value, :decimal, precision: 20, scale: 10, null: false
      add :total_value, :decimal, precision: 14, scale: 2
      add :additional_info, :text

      # Lot data, however we managed to get it.
      add :lot_number, :string
      add :manufactured_on, :date
      add :expires_on, :date
      add :lot_source, :string, null: false, default: "none"

      # Resolution: what this line became in our catalog.
      add :product_id, references(:products, on_delete: :nilify_all)
      add :conversion_factor, :decimal, precision: 16, scale: 4
      add :unit_cost, :decimal, precision: 20, scale: 10
      add :needs_review, :boolean, null: false, default: false
      add :review_notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoice_items, [:invoice_id, :item_number])
    create index(:invoice_items, [:product_id])
    create index(:invoice_items, [:gtin])

    create constraint(:invoice_items, :invoice_items_lot_source_must_be_known,
             check: "lot_source in ('rastro', 'inf_ad_prod', 'manual', 'none')"
           )

    create constraint(:invoice_items, :invoice_items_quantity_must_be_positive,
             check: "commercial_quantity > 0"
           )

    create constraint(:invoice_items, :invoice_items_conversion_factor_must_be_positive,
             check: "conversion_factor is null or conversion_factor > 0"
           )

    alter table(:transactions) do
      add :invoice_id, references(:invoices, on_delete: :restrict)
    end

    create index(:transactions, [:invoice_id])
  end
end
