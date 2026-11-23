defmodule EstoqueOSWeb.HomeActivityTest do
  @moduledoc """
  The recent-activity list says where a load went and what a manual issue took.

  Rendered against real records: `route/1` reads location associations, and an
  unloaded association is truthy, so a missing preload raises here.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  setup :register_and_log_in_operator

  test "a load-out says from where to where", %{conn: conn} do
    source = location_fixture(%{name: "Estoque Principal"})
    destination = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    box = box_fixture(%{location_id: source.id})
    lot = lot_fixture()

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [%{lot_id: lot.id, location_id: source.id, box_id: box.id, quantity: 30}]
      })

    {:ok, _} =
      Outbound.load_out(%{
        source_location_id: source.id,
        destination_location_id: destination.id,
        box_ids: [box.id],
        user_id: actor_id()
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Estoque Principal → Missão Tefé"
  end

  test "a manual issue says where to and what left", %{conn: conn} do
    product = product_fixture(%{name: "Compressa"})
    location = location_fixture()
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [%{lot_id: lot.id, location_id: location.id, quantity: 50}]
      })

    {:ok, _} =
      Outbound.issue(product.id, 10, %{
        location_id: location.id,
        user_id: actor_id(),
        destination: "triage"
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Triagem"
    assert html =~ "Compressa"
  end
end
