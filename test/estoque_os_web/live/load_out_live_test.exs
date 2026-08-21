defmodule EstoqueOSWeb.LoadOutLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Repo

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    box = box_fixture(%{code: "LO01", location_id: warehouse.id})
    product = product_fixture(%{name: "Eletrodo ECG adulto"})

    boxed = lot_fixture(%{product_id: product.id})
    loose = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-03-31]})

    stock_in(boxed, warehouse, 300, box_id: box.id)
    stock_in(loose, warehouse, 40)

    %{warehouse: warehouse, mission: mission, box: box, loose: loose}
  end

  defp stock_in(lot, location, quantity, opts \\ []) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity)
          }
        ]
      })
  end

  test "offers the boxes, and names the unboxed as something that cannot go", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/load-out")

    assert html =~ "Enviar carga"
    assert html =~ "LO01"
    assert html =~ "300"
    assert html =~ "Tudo vem selecionado"

    # The unboxed stock is reported, never offered: it has no input to type a
    # quantity into, and the screen says where to resolve it.
    assert html =~ "não estão em caixa e não podem viajar"
    refute html =~ ~s(name="picks)
  end

  test "asks before the whole warehouse leaves the building", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/load-out")

    # The ledger is append-only: the moment before the write is the only place
    # to be careful, so it states the consequence in the operation's numbers.
    assert html =~ "data-confirm-open=\"confirm-load-out\""
    assert html =~ "confirm-load-out"
    assert html =~ "<dialog"
    assert html =~ "Enviar esta carga?"
    assert html =~ "caixa(s) e"
    assert html =~ "Missão Tefé"
  end

  test "sends the whole load in one event", %{
    conn: conn,
    warehouse: warehouse,
    mission: mission,
    box: box
  } do
    {:ok, view, _html} = live(conn, ~p"/load-out")

    html = view |> element("#load-form") |> render_submit(%{"box_ids" => ["#{box.id}"]})

    assert html =~ "Carga enviada"
    assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(40))
    assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(300))
    assert Repo.reload!(box).location_id == mission.id
  end

  test "the box travels whole and the unboxed stays behind", %{
    conn: conn,
    warehouse: warehouse,
    mission: mission,
    box: box
  } do
    {:ok, view, _html} = live(conn, ~p"/load-out")

    view |> element("#load-form") |> render_submit(%{"box_ids" => ["#{box.id}"]})

    assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(300))

    # The 40 unboxed units wait for the conference rather than travelling.
    assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(40))
  end

  test "asks for something to send", %{conn: conn, box: box, mission: mission} do
    # With the box gone, the warehouse holds only unboxed stock — which is
    # exactly the case where there is nothing that can leave.
    {:ok, _} =
      EstoqueOS.Outbound.load_out(%{
        source_location_id: box.location_id,
        destination_location_id: mission.id,
        box_ids: [box.id],
        user_id: actor_id()
      })

    {:ok, view, html} = live(conn, ~p"/load-out")

    assert html =~ "não estão em caixa e não podem viajar"
    refute html =~ ~s(id="load-form")
    refute view |> has_element?("#load-form")
  end

  test "switching the origin reloads what is available", %{conn: conn, mission: mission} do
    {:ok, view, _html} = live(conn, ~p"/load-out")

    html =
      view
      |> element("#route-form")
      |> render_change(%{"source_id" => "#{mission.id}", "destination_id" => "#{mission.id}"})

    assert html =~ "Não há nada para enviar daqui"
  end
end
