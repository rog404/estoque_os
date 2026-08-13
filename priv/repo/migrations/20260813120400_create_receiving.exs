defmodule EstoqueOS.Repo.Migrations.CreateReceiving do
  use Ecto.Migration

  def change do
    # Checking what physically arrived against what the invoice promised.
    # A receipt can be repeated — the warehouse recounts when a divergence
    # looks like a miscount — so rounds are numbered per invoice.
    create table(:receipts) do
      add :invoice_id, references(:invoices, on_delete: :restrict), null: false
      add :location_id, references(:locations, on_delete: :restrict), null: false
      add :round, :integer, null: false, default: 1
      add :status, :string, null: false, default: "draft"
      add :counted_by_id, references(:users, on_delete: :nilify_all)
      add :completed_at, :utc_datetime
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:receipts, [:invoice_id, :round])
    create index(:receipts, [:status])

    create constraint(:receipts, :receipts_status_must_be_known,
             check: "status in ('draft', 'completed', 'cancelled')"
           )

    create constraint(:receipts, :receipts_round_must_be_positive, check: "round > 0")

    create table(:receipt_lines) do
      add :receipt_id, references(:receipts, on_delete: :delete_all), null: false
      add :invoice_item_id, references(:invoice_items, on_delete: :restrict), null: false
      # What the invoice promised, in stock units, frozen when the receipt
      # opened: the conference is against that number, not against a moving one.
      add :expected_quantity, :decimal, precision: 16, scale: 4, null: false
      add :counted_quantity, :decimal, precision: 16, scale: 4
      add :box_id, references(:boxes, on_delete: :restrict)
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:receipt_lines, [:receipt_id, :invoice_item_id])
    create index(:receipt_lines, [:box_id])

    create constraint(:receipt_lines, :receipt_lines_counted_must_not_be_negative,
             check: "counted_quantity is null or counted_quantity >= 0"
           )
  end
end
