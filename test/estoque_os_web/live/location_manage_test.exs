defmodule EstoqueOSWeb.LocationManageTest do
  @moduledoc """
  A location may be renamed and retired, never deleted: transactions name the
  location they moved stock from and to, so the row has to outlive its use.
  Retiring is `active: false`, which drops it out of `list_locations/0` and so
  out of every picker.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory.Locations

  setup :register_and_log_in_operator

  test "renames a location", %{conn: conn} do
    location = location_fixture(%{name: "Missao Tefe"})

    {:ok, view, _html} = live(conn, ~p"/locations")

    view |> element("button[phx-value-id='#{location.id}'][phx-click='edit']") |> render_click()

    html =
      view
      |> form("#rename-#{location.id}", %{"name" => "Missão Tefé"})
      |> render_submit()

    assert html =~ "Missão Tefé"
    assert Locations.get_location!(location.id).name == "Missão Tefé"
  end

  test "deactivating drops it out of every picker but keeps the row", %{conn: conn} do
    location = location_fixture(%{name: "Local Vazio"})

    {:ok, view, html} = live(conn, ~p"/locations")
    assert html =~ "Local Vazio"

    render_submit(element(view, "#deactivate-form-#{location.id}"), %{})

    refute Enum.any?(Locations.list_locations(), &(&1.id == location.id))
    assert Locations.get_location!(location.id).active == false
  end

  test "refuses to deactivate a location that still holds boxes", %{conn: conn} do
    location = location_fixture(%{name: "Com Caixa"})
    box_fixture(%{location_id: location.id})

    {:ok, view, html} = live(conn, ~p"/locations")

    # The trigger is offered, disabled, and says what would make it work. Gone
    # entirely, it read as a feature this row does not have — the operator could
    # not tell "not yet" from "never" from "broken".
    trigger =
      Regex.run(~r{<button[^>]*data-confirm-open="deactivate-#{location.id}"[^>]*>}, html) |> hd()

    assert trigger =~ "disabled"
    assert html =~ "Mova ou desative as caixas dele primeiro."

    # ...and the event is refused if it arrives anyway.
    assert render_submit(view, "deactivate", %{"id" => location.id}) =~ "Mova"
    assert Locations.get_location!(location.id).active == true
  end

  test "counts boxes rather than loose units", %{conn: conn} do
    location = location_fixture(%{name: "Com Duas"})
    box_fixture(%{location_id: location.id})
    box_fixture(%{location_id: location.id})

    {:ok, _view, html} = live(conn, ~p"/locations")

    assert html =~ "Caixas" or html =~ "Boxes"
    refute html =~ "Unidades"
  end
end
