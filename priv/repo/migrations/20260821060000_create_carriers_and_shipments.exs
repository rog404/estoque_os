defmodule EstoqueOS.Repo.Migrations.CreateCarriersAndShipments do
  @moduledoc """
  The load itself becomes a thing.

  Sending a mission's supplies out and receiving them back were two screens
  with nothing between them: the ledger could say stock was in transit and
  nothing more — not with whom, not since when, not expected where, and above
  all not *which load*, because "Trânsito" is one location and two shipments
  travelling at once land in the same bucket.

  So the shipment is the record, and it is the thing both screens are about:
  one creates it, the other closes it. That is also what the two screens turn
  out to be — the same act in opposite directions.

  `locations` keeps its `transit` kind. Every balance in this system is a
  quantity somewhere, and goods on a truck have to be somewhere: leaving them
  at the origin makes the origin's balance a lie, and "estoque em trânsito" is
  a figure the accountant asks for by name (SPEC §3.5). The place holds the
  balance; the shipment holds everything the place cannot know.

  Carriers get a table for the reason SPEC §3.13 gives about product names, and
  which killed a previous system: "STRALOG", "Stralog" and "Stralog Ltda" typed
  on three trips are three carriers, and then nothing can be asked about any of
  them.
  """

  use Ecto.Migration

  def change do
    create table(:carriers) do
      add :legal_name, :string, null: false
      add :trade_name, :string
      # Digits only, normalised by the changeset: a CNPJ typed with dots and
      # slashes never matches itself across two entries.
      add :cnpj, :string
      add :email, :string
      add :phone, :string
      add :notes, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:carriers, ["lower(legal_name)"], name: :carriers_lower_legal_name_index)
    create unique_index(:carriers, [:cnpj], where: "cnpj IS NOT NULL")

    create table(:shipments) do
      add :from_location_id, references(:locations, on_delete: :restrict), null: false
      add :to_location_id, references(:locations, on_delete: :restrict), null: false
      # Nullable: a volunteer's car is not a carrier, and refusing to record the
      # trip because nobody was hired for it would lose the trip.
      add :carrier_id, references(:carriers, on_delete: :restrict)
      # The conhecimento de transporte, or whatever number the carrier gives you
      # to ask about the load later. Free text: every carrier numbers
      # differently, and the point is being able to quote it back.
      add :waybill, :string
      add :shipped_on, :date, null: false
      add :expected_arrival, :date
      # Open while null. Derived state rather than a stored status column, for
      # the same reason balances are derived: two places to write "received" is
      # one place to disagree.
      add :received_at, :utc_datetime
      add :received_by_id, references(:users, on_delete: :nilify_all)
      add :mission_id, references(:missions, on_delete: :nilify_all)
      add :notes, :string

      # The two movements this shipment is bracketed by. The first is what took
      # the goods out; the second is what brought them in, and it is null for as
      # long as the load is on the road.
      add :sent_transaction_id, references(:transactions, on_delete: :restrict), null: false
      add :received_transaction_id, references(:transactions, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    # The transit report is this index: what is still out, oldest first, because
    # the load that left three weeks ago is the one worth a phone call.
    create index(:shipments, [:shipped_on], where: "received_at IS NULL", name: :shipments_open)
    create index(:shipments, [:carrier_id])
    create index(:shipments, [:sent_transaction_id])

    create constraint(:shipments, :shipments_must_travel_between_two_places,
             check: "from_location_id <> to_location_id"
           )

    create constraint(:shipments, :shipments_received_needs_both_or_neither,
             check: """
             (received_at IS NULL AND received_transaction_id IS NULL)
             OR (received_at IS NOT NULL AND received_transaction_id IS NOT NULL)
             """
           )
  end
end
