defmodule EstoqueOSWeb.BoxLookupTest do
  @moduledoc "The authenticated box lookup at `/boxes/lookup`."

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "CX01", location_id: warehouse.id})
    gauze = product_fixture(%{name: "Gaze estéril"})
    lot = lot_fixture(%{product_id: gauze.id, expires_on: ~D[2027-09-30]})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: warehouse.id, box_id: box.id, quantity: Decimal.new(40)}
        ]
      })

    %{warehouse: warehouse, box: box}
  end

  test "opens for an authorised user", %{conn: conn} do
    assert {:ok, _lv, html} = live(conn, ~p"/boxes/lookup")
    # pt_BR translation, not the English msgid.
    assert html =~ "O que tem nesta caixa"
  end

  test "a typed code shows what the box holds", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/boxes/lookup")

    html = lv |> form("#lookup-form", %{code: "CX01"}) |> render_submit()

    assert html =~ "CX01"
    assert html =~ "Gaze estéril"
    assert html =~ "40"
  end

  test "the lookup ignores the typed case", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/boxes/lookup")

    html = lv |> form("#lookup-form", %{code: "cx01"}) |> render_submit()

    assert html =~ "Gaze estéril"
  end

  test "a code opening the page directly answers on mount", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/boxes/lookup?code=CX01")

    assert html =~ "Gaze estéril"
  end

  test "an unknown code says so instead of crashing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/boxes/lookup")

    html = lv |> form("#lookup-form", %{code: "NAO-EXISTE"}) |> render_submit()

    refute html =~ "Gaze estéril"
    assert html =~ "NAO-EXISTE"
  end
end
