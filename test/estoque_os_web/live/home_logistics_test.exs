defmodule EstoqueOSWeb.HomeLogisticsTest do
  @moduledoc """
  Reported from the field: the logistics operator does not see Recent activity.

  Nothing in the code explains it — `Reports.recent_activity/1` filters by no
  role, and `HomeLive.Index` sits in the `:signed_in` live_session that every
  authenticated role mounts. These tests are the reproduction attempt, kept
  because they pin down what the operator is entitled to see: the movements,
  yes; the amounts, no.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  setup :register_and_log_in_logistics

  setup do
    source = location_fixture(%{name: "Estoque Principal"})
    destination = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    box = box_fixture(%{location_id: source.id})
    product = product_fixture(%{name: "Compressa 10x10"})
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: source.id,
            box_id: box.id,
            quantity: 30,
            unit_cost: Decimal.new("2.50")
          }
        ]
      })

    {:ok, _} =
      Outbound.load_out(%{
        source_location_id: source.id,
        destination_location_id: destination.id,
        box_ids: [box.id],
        user_id: actor_id()
      })

    %{source: source, destination: destination}
  end

  test "the logistics operator sees the recent activity list", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Atividade recente"
    assert html =~ "Derrubada de carga"
    assert html =~ "Estoque Principal → Missão Tefé"
    refute html =~ "Nada se moveu ainda"
  end

  test "and still gets no amounts anywhere on the page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "Valor conhecido"
    refute html =~ "R$"
  end
end
