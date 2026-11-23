defmodule EstoqueOS.SeedsLocationsTest do
  @moduledoc """
  Deliberately serial. `locations` has a unique index on `lower(name)`, and these
  tests must use the real names ("Estoque Principal" is the configured default
  location), which other suites also use in fixtures. Concurrent inserts of the
  same names hold locks while waiting, so suites reaching a pair in opposite
  orders deadlock.
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
