defmodule EstoqueOS.Repo.Migrations.CreateInventory do
  @moduledoc """
  Where stock lives, what it is a lot of, and the ledger that moves it.

  Three things in `transactions` are load-bearing enough to state rather than
  leave implicit.

  `user_id` is required, with `on_delete: :restrict`. A ledger that has to answer
  "who took the ketamine out" in front of a Brazilian auditor cannot let deleting
  an account erase that person from every movement they ever made. Users are
  deactivated, never deleted.

  `destination` is a value, not prose. The screen asks "where to / why", and if
  the answer lived only in `notes` then the one question the operation actually
  needs to ask of the ledger — what did we give away — could only be answered by
  reading every line by eye. `recipient_name` and `recipient_tax_id` name the
  institution a donation went to, both optional: the operation wants to be able
  to record them, not to be blocked when nobody has them at hand.

  `review_reason` flags a count that still disagreed with the ledger after being
  taken twice; null for the overwhelming majority of movements, which is the
  point.

  Two columns are missing on purpose. `invoice_id` arrives with `CreateInvoices`
  and `mission_id` / `source_mission_id` with `CreateMissions` — a movement can
  point at either, but neither table exists yet, and a migration that refers
  forward cannot be run on its own.
  """

  use Ecto.Migration

  def change do
    # Tree: warehouse(s) -> mission sites -> transit. "transit" mirrors the
    # accounting concept of estoque em trânsito.
    create table(:locations) do
      add :parent_id, references(:locations, on_delete: :restrict)
      add :name, :string, null: false
      add :kind, :string, null: false
      add :notes, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:locations, ["lower(name)"], name: :locations_lower_name_index)
    create index(:locations, [:parent_id])

    create constraint(:locations, :locations_kind_must_be_known,
             check: "kind in ('warehouse', 'mission_site', 'transit', 'other')"
           )

    # Movable containers (AN01, JP04...). Moving a box moves its presumed
    # contents without an item-level recount; last_verified_at records when
    # the contents were last actually counted.
    create table(:boxes) do
      add :code, :string, null: false
      add :location_id, references(:locations, on_delete: :restrict), null: false
      add :last_verified_at, :utc_datetime
      add :notes, :text
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boxes, ["upper(code)"], name: :boxes_upper_code_index)
    create index(:boxes, [:location_id])

    create table(:lots) do
      add :product_id, references(:products, on_delete: :restrict), null: false
      # Null means "lot unknown" — a last-resort placeholder, flagged so the
      # receiving screen can ask for it later. Only one per product.
      add :lot_number, :string
      add :manufactured_on, :date
      add :expires_on, :date
      add :needs_review, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:lots, [:product_id, :lot_number], nulls_distinct: false)
    create index(:lots, [:expires_on])

    create constraint(:lots, :lots_manufactured_before_expiry,
             check:
               "manufactured_on is null or expires_on is null or manufactured_on <= expires_on"
           )

    # The ledger. Stock is never stored as a balance: every change is an
    # append-only transaction with signed entries.
    create table(:transactions) do
      add :type, :string, null: false
      add :occurred_at, :utc_datetime, null: false
      add :source_location_id, references(:locations, on_delete: :restrict)
      add :destination_location_id, references(:locations, on_delete: :restrict)
      add :reason_code, :string
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :notes, :text
      add :destination, :string
      add :recipient_tax_id, :string
      add :recipient_name, :string
      add :review_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:type])
    create index(:transactions, [:occurred_at])
    create index(:transactions, [:destination])

    # Only the flagged ones are ever queried, and they are a rounding error of
    # the table.
    create index(:transactions, [:review_reason],
             where: "review_reason IS NOT NULL",
             name: :transactions_needing_review
           )

    create constraint(:transactions, :transactions_destination_must_be_known,
             check: """
             destination IS NULL OR destination IN
               ('pacu', 'operating_room', 'donation', 'pre_and_post', 'triage')
             """
           )

    create constraint(:transactions, :transactions_type_must_be_known,
             check: """
             type in ('purchase_in', 'donation_in', 'transfer', 'load_out',
                      'return_in', 'kit_assembly', 'kit_consumption',
                      'manual_out', 'adjustment', 'inventory_import')
             """
           )

    # Adjustments without a reason are exactly what makes a stock unauditable.
    create constraint(:transactions, :transactions_adjustments_need_a_reason,
             check: """
             type <> 'adjustment' or reason_code in
               ('expiry', 'damage', 'loss', 'count_correction', 'other')
             """
           )

    create constraint(:transactions, :transactions_transfers_need_both_locations,
             check: """
             type not in ('transfer', 'load_out')
               or (source_location_id is not null and destination_location_id is not null)
             """
           )

    create table(:transaction_entries) do
      add :transaction_id, references(:transactions, on_delete: :delete_all), null: false
      add :lot_id, references(:lots, on_delete: :restrict), null: false
      add :box_id, references(:boxes, on_delete: :restrict)
      add :location_id, references(:locations, on_delete: :restrict), null: false
      # Signed: positive adds to the location, negative removes from it.
      add :quantity, :decimal, precision: 16, scale: 4, null: false
      # Null means "value not informed" (donations). Never a symbolic cent:
      # 0.01 poisons average cost and stock value reports.
      add :unit_cost, :decimal, precision: 20, scale: 10

      timestamps(type: :utc_datetime)
    end

    create index(:transaction_entries, [:transaction_id])
    create index(:transaction_entries, [:lot_id])
    create index(:transaction_entries, [:box_id])
    create index(:transaction_entries, [:location_id])

    create constraint(:transaction_entries, :transaction_entries_quantity_must_not_be_zero,
             check: "quantity <> 0"
           )

    create constraint(:transaction_entries, :transaction_entries_unit_cost_must_be_positive,
             check: "unit_cost is null or unit_cost > 0"
           )

    # Rollup cache, refreshed inside the same transaction that writes entries.
    # It is NEVER a source of truth: `Inventory.balance/1` can always be
    # recomputed from transaction_entries, and a test asserts they agree.
    create table(:stock_snapshots) do
      add :lot_id, references(:lots, on_delete: :delete_all), null: false
      add :box_id, references(:boxes, on_delete: :delete_all)
      add :location_id, references(:locations, on_delete: :delete_all), null: false
      add :quantity, :decimal, precision: 16, scale: 4, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stock_snapshots, [:lot_id, :box_id, :location_id], nulls_distinct: false)
    create index(:stock_snapshots, [:location_id])
    create index(:stock_snapshots, [:box_id])
  end
end
