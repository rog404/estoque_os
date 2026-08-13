defmodule EstoqueOS.Missions.Mission do
  @moduledoc """
  One surgical trip: where it went, when, and how big it was.

  A mission is not the same thing as the location it happens at. The ONG returns
  to the same cities, so "Tefé" answers where and nothing else; "Tefé 2026/1"
  answers which trip, which is the unit the coordinator is accountable for.

  `ends_on` is required. The flight home is booked before the team leaves, so the
  date is known when the trip is created — it is simply subject to change, which
  is what editing is for. Leaving it blank also made a mission's range unbounded
  above, and since trips at one place may not overlap, one open mission blocked
  its site for good.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias EstoqueOS.Inventory.Location

  schema "missions" do
    field :name, :string
    field :starts_on, :date
    field :ends_on, :date
    field :tables, :integer
    field :notes, :string

    belongs_to :location, Location

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(mission, attrs) do
    mission
    |> cast(attrs, [:name, :location_id, :starts_on, :ends_on, :tables, :notes])
    |> validate_required([:name, :location_id, :starts_on, :ends_on])
    |> validate_number(:tables, greater_than: 0)
    |> validate_ends_on_after_starts_on()
    |> assoc_constraint(:location)
    |> unique_constraint(:name, name: :missions_lower_name_index)
    |> check_constraint(:ends_on, name: :missions_must_not_end_before_it_starts)
    |> check_constraint(:tables, name: :missions_tables_must_be_positive)
    |> validate_no_overlap()
    |> exclusion_constraint(:starts_on,
      name: :missions_must_not_overlap_at_a_place,
      message: "overlaps another mission at this place"
    )
  end

  # The database is what actually guarantees this — two people creating trips at
  # the same instant is a race no query can see. This is here so the ordinary
  # case gets a sentence rather than a constraint violation.
  defp validate_no_overlap(changeset) do
    location_id = get_field(changeset, :location_id)
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)
    id = get_field(changeset, :id)

    if (changeset.valid? and location_id) && starts_on do
      overlapping =
        __MODULE__
        |> where([m], m.location_id == ^location_id)
        |> then(&if(id, do: where(&1, [m], m.id != ^id), else: &1))
        |> where([m], is_nil(m.ends_on) or m.ends_on >= ^starts_on)
        |> then(fn query ->
          if ends_on, do: where(query, [m], m.starts_on <= ^ends_on), else: query
        end)
        |> EstoqueOS.Repo.exists?()

      if overlapping do
        add_error(changeset, :starts_on, "overlaps another mission at this place")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_ends_on_after_starts_on(changeset) do
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)

    if starts_on && ends_on && Date.compare(ends_on, starts_on) == :lt do
      add_error(changeset, :ends_on, "cannot be before the start")
    else
      changeset
    end
  end
end
