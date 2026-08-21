defmodule EstoqueOS.Repo.Migrations.AddSalePrice do
  @moduledoc """
  What something went out *for*, beside what it came in *at*.

  The marketing stock is sold, so a write-off of it has two numbers and they
  answer different questions: `unit_cost` is what the ONG paid, and
  `sale_unit_price` is what the buyer paid. Keeping the second in `unit_cost`
  would have destroyed the first — average cost is derived from it, and stock
  value with it.

  Nullable, and null nearly always: only a sale carries one.
  """

  use Ecto.Migration

  def up do
    alter table(:transaction_entries) do
      add :sale_unit_price, :decimal, precision: 15, scale: 4
    end

    drop constraint(:transactions, :transactions_destination_must_be_known)

    create constraint(:transactions, :transactions_destination_must_be_known,
             check: """
             destination IS NULL OR destination IN
               ('pacu', 'operating_room', 'donation', 'pre_and_post', 'triage',
                'disposal', 'sale')
             """
           )
  end

  def down do
    alter table(:transaction_entries) do
      remove :sale_unit_price
    end

    drop constraint(:transactions, :transactions_destination_must_be_known)

    create constraint(:transactions, :transactions_destination_must_be_known,
             check: """
             destination IS NULL OR destination IN
               ('pacu', 'operating_room', 'donation', 'pre_and_post', 'triage', 'disposal')
             """
           )
  end
end
