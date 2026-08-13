defmodule EstoqueOS.SeedsLocationsTest do
  @moduledoc """
  Split out of `SeedsTest`, and deliberately serial.

  `locations` carries a unique index on `lower(name)`, and these are the only
  tests that must use the real names — "Estoque Principal" in particular, because
  `config :estoque_os, :default_location_name` points at it and
  `Locations.default_location/0` looks it up by name. Two dozen other suites
  create locations with those same names for their own fixtures.

  Concurrent inserts of the same name do not merely queue: each transaction
  holds the names it already inserted while waiting for the next, so two suites
  that reach the same pair in opposite orders deadlock. It failed roughly one run
  in five, always here, because this is the suite that inserts all three canonical
  names in one go.

  Running these two serially takes them out of every cycle. It costs nothing
  measurable — the slow half of the seeds, the two spreadsheets, stays async in
  `SeedsTest`.
  """

  use EstoqueOS.DataCase, async: false

  alias EstoqueOS.Inventory.Location
  alias EstoqueOS.Seeds

  test "creates the warehouses and the transit location" do
    Seeds.seed_locations()

    assert Repo.get_by(Location, name: "Estoque Principal").kind == "warehouse"
    assert Repo.get_by(Location, name: "Escritório SP").kind == "warehouse"
    assert Repo.get_by(Location, name: "Trânsito").kind == "transit"
  end

  test "running twice does not duplicate them" do
    Seeds.seed_locations()
    Seeds.seed_locations()

    assert Repo.aggregate(Location, :count) == 3
  end
end
