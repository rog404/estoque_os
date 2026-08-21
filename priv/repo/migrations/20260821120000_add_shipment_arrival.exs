defmodule EstoqueOS.Repo.Migrations.AddShipmentArrival do
  use Ecto.Migration

  @moduledoc """
  A load carried by somebody else stops at transit on the way.

  When the ONG drives its own goods to a mission, sending them and them being
  there is one act. When a carrier takes them, it is two: the truck leaves on a
  Tuesday and arrives on a Friday, and between those days the stock is neither
  in the warehouse nor at the mission. `arrived_at` is what closes that gap —
  null while the load is on the road, stamped when somebody at the other end
  says it landed.

  Separate from `received_at`, which means something else entirely: received is
  the mission handing back what it did not use.
  """

  def change do
    alter table(:shipments) do
      add :arrived_at, :utc_datetime
      add :arrival_transaction_id, references(:transactions, on_delete: :restrict)
    end

    create index(:shipments, [:arrival_transaction_id])

    # The stamp and the movement that made it travel together, exactly as the
    # receipt pair already does: one without the other is a claim with no ledger
    # entry behind it, or an entry nothing points at.
    create constraint(:shipments, :shipments_arrival_needs_both_or_neither,
             check: "(arrived_at IS NULL) = (arrival_transaction_id IS NULL)"
           )
  end
end
