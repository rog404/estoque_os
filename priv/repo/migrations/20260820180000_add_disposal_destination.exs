defmodule EstoqueOS.Repo.Migrations.AddDisposalDestination do
  @moduledoc """
  "Descarte" as a place goods can go.

  Everything else in the destination list is somewhere the goods were used or
  given away; this is the one where they were thrown out. It was being written
  as a donation with a note, or as an adjustment, and neither answers the
  question the list exists to answer — how much of what we bought ended in the
  bin.
  """

  use Ecto.Migration

  def up do
    drop constraint(:transactions, :transactions_destination_must_be_known)

    create constraint(:transactions, :transactions_destination_must_be_known,
             check: """
             destination IS NULL OR destination IN
               ('pacu', 'operating_room', 'donation', 'pre_and_post', 'triage', 'disposal')
             """
           )
  end

  def down do
    drop constraint(:transactions, :transactions_destination_must_be_known)

    create constraint(:transactions, :transactions_destination_must_be_known,
             check: """
             destination IS NULL OR destination IN
               ('pacu', 'operating_room', 'donation', 'pre_and_post', 'triage')
             """
           )
  end
end
