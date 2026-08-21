defmodule EstoqueOS.Repo.Migrations.AddLocationDefaultSegment do
  use Ecto.Migration

  # Which stock a place is the default entry point for. The two stocks share the
  # warehouse and the boxes, but not the door goods come in through: surgical
  # supplies arrive at the warehouse and marketing material arrives at the São
  # Paulo office, and every screen that preselected "the default location" was
  # sending the marketing coordinator to the wrong shelf on every entry.
  def change do
    alter table(:locations) do
      add :default_for_segment, :string
    end

    create constraint(:locations, :locations_default_segment_must_be_known,
             check:
               "default_for_segment is null or default_for_segment in ('medical', 'marketing')"
           )

    # One default per stock. Two places both claiming to be where marketing
    # material arrives is a question the screens would answer by row id.
    create unique_index(:locations, [:default_for_segment],
             where: "default_for_segment is not null",
             name: :locations_one_default_per_segment
           )
  end
end
