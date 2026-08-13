defmodule EstoqueOS.Repo.Migrations.CreateMissions do
  @moduledoc """
  The week-long surgical trip the whole operation is organised around.

  `tables` is how the operation sizes a mission — the standard supply table is
  written for four. Keeping it here is what makes two missions comparable:
  consumption per table means something, consumption per mission does not.

  Movements point at the mission rather than the mission listing its movements:
  the ledger is the record, and this is a lens onto it. `mission_id` and
  `source_mission_id` name, respectively, the trip goods arrived at and the trip
  they left — stock does not always come home between trips, so a box can go
  warehouse -> mission -> mission -> warehouse. Without the second one, the
  departing mission's panel would count those goods as sent and never accounted
  for. Both are added to `transactions` from here: the ledger predates the
  mission, and a movement without one is the ordinary case.

  `ends_on` is required: the flight home is booked before the team leaves, and
  the date is known — it is simply subject to change, which is what editing is
  for. A missing return date would also leave a mission's place blocked
  forever, because the overlap exclusion below treats a null `ends_on` as an
  unbounded range.

  The exclusion constraint enforces one trip at a time in one place. It is not
  a check in Elixir because the race it prevents — two people creating
  overlapping trips at the same moment — is invisible to application-level
  validation. `btree_gist` is what lets an integer equality sit alongside a
  range overlap in the same constraint. Two missions in different places may
  run at once, and are expected to: the rule is per place, not global.
  """

  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist", ""

    create table(:missions) do
      add :name, :string, null: false
      add :location_id, references(:locations, on_delete: :restrict), null: false
      add :starts_on, :date, null: false
      add :ends_on, :date, null: false
      add :tables, :integer
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:missions, ["lower(name)"], name: :missions_lower_name_index)
    create index(:missions, [:location_id])
    create index(:missions, [:starts_on])

    create constraint(:missions, :missions_must_not_end_before_it_starts,
             check: "ends_on IS NULL OR ends_on >= starts_on"
           )

    create constraint(:missions, :missions_tables_must_be_positive,
             check: "tables IS NULL OR tables > 0"
           )

    execute """
            ALTER TABLE missions
              ADD CONSTRAINT missions_must_not_overlap_at_a_place
              EXCLUDE USING gist (
                location_id WITH =,
                daterange(starts_on, ends_on, '[]') WITH &&
              )
            """,
            "ALTER TABLE missions DROP CONSTRAINT missions_must_not_overlap_at_a_place"

    alter table(:transactions) do
      add :mission_id, references(:missions, on_delete: :restrict)
      add :source_mission_id, references(:missions, on_delete: :restrict)
    end

    create index(:transactions, [:mission_id])
    create index(:transactions, [:source_mission_id])
  end
end
