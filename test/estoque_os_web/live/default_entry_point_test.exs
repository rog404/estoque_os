defmodule EstoqueOSWeb.DefaultEntryPointTest do
  @moduledoc """
  Which door goods come in through, per stock.

  The two stocks share the warehouse and the boxes, but not the place a
  delivery lands: surgical supplies arrive at the warehouse and marketing
  material at the São Paulo office. Every screen that preselects a location used
  to read one global default, so one of the two coordinators corrected it by
  hand on every single entry.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory.Locations

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    office = location_fixture(%{name: "Escritório São Paulo", kind: "other"})

    %{warehouse: warehouse, office: office}
  end

  defp mark(location, segment) do
    {:ok, updated} = Locations.set_default_for_segment(location, segment)
    updated
  end

  test "the manual entry opens at the door that stock comes in through", %{
    conn: conn,
    warehouse: warehouse,
    office: office
  } do
    mark(warehouse, "medical")
    mark(office, "marketing")

    {:ok, _view, surgical} = live(conn, ~p"/entry")
    assert surgical =~ ~s{value="#{warehouse.id}" selected}

    {:ok, _view, marketing} = live(conn, ~p"/entry?segment=marketing")
    assert marketing =~ ~s{value="#{office.id}" selected}
  end

  # One per stock: two places both claiming to be where marketing material
  # arrives is a question the screens would answer by row id.
  test "marking a second place moves the mark", %{
    conn: conn,
    warehouse: warehouse,
    office: office
  } do
    mark(warehouse, "marketing")

    {:ok, view, _html} = live(conn, ~p"/locations")

    view
    |> form("#default-#{office.id}", %{"location_id" => "#{office.id}", "segment" => "marketing"})
    |> render_change()

    assert Locations.get_location!(office.id).default_for_segment == "marketing"
    refute Locations.get_location!(warehouse.id).default_for_segment
  end

  test "the mark can be taken off", %{conn: conn, office: office} do
    mark(office, "marketing")

    {:ok, view, _html} = live(conn, ~p"/locations")

    view
    |> form("#default-#{office.id}", %{"location_id" => "#{office.id}", "segment" => ""})
    |> render_change()

    refute Locations.get_location!(office.id).default_for_segment
  end

  # Nothing marked is the state every install starts in, and the old behaviour
  # is what has to answer then.
  test "falls back to the warehouse while nothing is marked", %{warehouse: warehouse} do
    assert Locations.default_location("marketing").id == warehouse.id
    assert Locations.default_location().id == warehouse.id
  end

  test "a deactivated place stops being the door", %{warehouse: warehouse, office: office} do
    mark(office, "marketing")
    {:ok, _} = Locations.deactivate_location(office)

    assert Locations.default_location("marketing").id == warehouse.id
  end
end
