defmodule EstoqueOSWeb.TransitTest do
  @moduledoc """
  The load as a record, answering "quem está com a carga?": with whom, since
  when, and expected where, even with two loads travelling at once.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Catalog, Inventory, Outbound, Repo}
  alias EstoqueOS.Outbound.Shipment

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    transit = location_fixture(%{name: "Trânsito", kind: "transit"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    box = box_fixture(%{code: "TR01", location_id: warehouse.id})

    product = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            box_id: box.id,
            location_id: warehouse.id,
            quantity: Decimal.new(300)
          }
        ]
      })

    %{warehouse: warehouse, transit: transit, mission: mission, box: box, lot: lot}
  end

  defp send_load(view, params) do
    view |> element("#load-form") |> render_submit(params)
  end

  describe "sending a load" do
    test "records who is carrying it, under which number, and when it is due", %{
      conn: conn,
      box: box,
      mission: mission,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG",
        "waybill" => "CTE-99182",
        "expected_arrival" => "#{Date.add(Date.utc_today(), 5)}"
      })

      assert [%Shipment{} = shipment] = Repo.all(Shipment) |> Repo.preload(:carrier)

      assert shipment.carrier.legal_name == "STRALOG"
      assert shipment.waybill == "CTE-99182"
      assert shipment.expected_arrival == Date.add(Date.utc_today(), 5)
      assert shipment.shipped_on == Date.utc_today()
      # Open (no `received_at`) is what "still out there" means; there is no status column.
      assert is_nil(shipment.received_at)
      assert shipment.sent_transaction_id
    end

    # "STRALOG" and "Stralog" must be one carrier, or nothing can be asked about either.
    test "the same carrier typed differently is the same carrier", %{
      conn: conn,
      box: box,
      mission: mission,
      warehouse: warehouse
    } do
      {:ok, _carrier} = Catalog.resolve_carrier("STRALOG")

      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "  stralog "
      })

      assert length(Catalog.list_carriers()) == 1
    end

    test "a load the team carries itself is still a load", %{
      conn: conn,
      box: box,
      mission: mission,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => ""
      })

      assert [shipment] = Repo.all(Shipment)
      assert is_nil(shipment.carrier_id)
      assert Catalog.list_carriers() == []
    end
  end

  describe "the transit report" do
    setup %{conn: conn, box: box, mission: mission, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG",
        "waybill" => "CTE-99182",
        "expected_arrival" => "#{Date.add(Date.utc_today(), 5)}"
      })

      :ok
    end

    test "answers who is carrying what", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/reports/transit")

      assert html =~ "STRALOG"
      assert html =~ "CTE-99182"
      assert html =~ "Estoque Principal"
      # The address is the destination; transit is a state, shown in its own column.
      assert html =~ "Missão Tefé"
      assert html =~ "na estrada"
      assert html =~ "1 carga(s) ainda na estrada"
    end

    test "shows nothing once the load is received", %{conn: conn, warehouse: warehouse} do
      [%{shipment: shipment}] = Outbound.open_shipments()

      # A carried load stops at transit, so it must land before anything is handed back.
      {:ok, %{shipment: shipment}} =
        Outbound.arrive_shipment(shipment, user_id: actor_id())

      lines =
        Enum.map(Outbound.plan_return(shipment.to_location_id), fn line ->
          %{
            lot_id: line.lot_id,
            from_box_id: line.box_id,
            to_box_id: line.box_id,
            quantity: line.expected,
            expected: line.expected
          }
        end)

      assert {:ok, %{shipment: closed}} =
               Outbound.receive_shipment(shipment, %{
                 destination_location_id: warehouse.id,
                 lines: lines,
                 user_id: actor_id()
               })

      assert closed.received_at
      assert closed.received_transaction_id
      assert Outbound.open_shipments() == []

      {:ok, _view, html} = live(conn, ~p"/reports/transit")
      assert html =~ "Nada está na estrada"
    end

    test "a load received twice is refused", %{conn: conn, warehouse: warehouse} do
      _ = conn
      [%{shipment: shipment}] = Outbound.open_shipments()

      {:ok, %{shipment: shipment}} =
        Outbound.arrive_shipment(shipment, user_id: actor_id())

      lines =
        Enum.map(Outbound.plan_return(shipment.to_location_id), fn line ->
          %{
            lot_id: line.lot_id,
            from_box_id: line.box_id,
            to_box_id: line.box_id,
            quantity: line.expected,
            expected: line.expected
          }
        end)

      {:ok, %{shipment: closed}} =
        Outbound.receive_shipment(shipment, %{
          destination_location_id: warehouse.id,
          lines: lines,
          user_id: actor_id()
        })

      assert {:error, :already_received} =
               Outbound.receive_shipment(closed, %{
                 destination_location_id: warehouse.id,
                 lines: lines,
                 user_id: actor_id()
               })
    end
  end

  describe "transit is where a carried load rests" do
    test "a load with a carrier stops at transit, addressed to the mission", %{
      conn: conn,
      box: box,
      lot: lot,
      mission: mission,
      transit: transit,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG"
      })

      # The goods are on a truck, so the balance says transit, not the mission.
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: transit.id), 300)
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: mission.id), 0)
      assert Repo.reload!(box).location_id == transit.id

      assert [%Shipment{} = shipment] = Repo.all(Shipment)
      assert shipment.to_location_id == mission.id
      assert is_nil(shipment.arrived_at)
      assert Shipment.in_transit?(shipment)
    end

    test "a load the team drives goes straight there", %{
      conn: conn,
      box: box,
      lot: lot,
      mission: mission,
      transit: transit,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => ""
      })

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: mission.id), 300)
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: transit.id), 0)

      [%Shipment{} = shipment] = Repo.all(Shipment)
      refute Shipment.in_transit?(shipment)
    end

    test "transit is not offered as a destination", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      refute has_element?(view, ~s{#route-form select[name="destination_id"] option}, "Trânsito")
    end

    test "confirming the arrival finishes the trip", %{
      conn: conn,
      box: box,
      lot: lot,
      mission: mission,
      transit: transit,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG"
      })

      {:ok, report, _html} = live(conn, ~p"/reports/transit")

      html =
        report
        |> element(~s{button[phx-click="arrive"]})
        |> render_click()

      assert html =~ "Missão Tefé"

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: mission.id), 300)
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: transit.id), 0)
      assert Repo.reload!(box).location_id == mission.id

      [%Shipment{} = shipment] = Repo.all(Shipment)
      assert shipment.arrived_at
      assert shipment.arrival_transaction_id
      # Arrived is not received: the mission still has to hand back what it did not use.
      assert is_nil(shipment.received_at)
    end

    test "a load that already landed cannot land again", %{
      conn: conn,
      box: box,
      mission: mission,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG"
      })

      [%{shipment: shipment}] = Outbound.open_shipments()
      {:ok, %{shipment: landed}} = Outbound.arrive_shipment(shipment, user_id: actor_id())

      assert {:error, :not_in_transit} = Outbound.arrive_shipment(landed, user_id: actor_id())
    end
  end

  describe "receiving by load" do
    setup %{conn: conn, box: box, lot: lot, mission: mission, warehouse: warehouse} do
      # A second box, as somewhere for the return to land.
      home = box_fixture(%{code: "TR09", location_id: warehouse.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              box_id: home.id,
              location_id: warehouse.id,
              quantity: Decimal.new(50)
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG",
        "waybill" => "CTE-99182"
      })

      [%{shipment: sent}] = Outbound.open_shipments()
      {:ok, %{shipment: landed}} = Outbound.arrive_shipment(sent, user_id: actor_id())

      %{shipment: landed, home: home}
    end

    # A load received as a loose return would stay "still out there" forever.
    test "choosing the load fills the route and closes the shipment", %{
      conn: conn,
      lot: lot,
      shipment: shipment,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/returns")

      routed =
        view
        |> element("#route-form")
        |> render_change(%{"shipment_id" => "#{shipment.id}"})

      assert routed =~ "Missão Tefé"

      [line] = Outbound.plan_return(shipment.to_location_id)

      html =
        view
        |> element("#return-form")
        |> render_submit(%{
          "lines" => %{
            "0" => %{
              "lot_id" => "#{line.lot_id}",
              "from_box_id" => "#{line.box_id}",
              "expected" => "300",
              "quantity" => "300",
              "to_box_code" => "TR09"
            }
          }
        })

      assert html =~ "Retorno recebido"
      assert Outbound.open_shipments() == []
      assert Repo.reload!(shipment).received_at
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, location_id: warehouse.id), 350)
    end

    test "a load still on the road is not offered here", %{
      conn: conn,
      home: home,
      mission: mission,
      shipment: landed,
      warehouse: warehouse
    } do
      {:ok, loader, _html} = live(conn, ~p"/load-out")

      send_load(loader, %{
        "box_ids" => ["#{home.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{mission.id}",
        "carrier" => "STRALOG"
      })

      [%{shipment: rolling}] = Enum.filter(Outbound.open_shipments(), & &1.in_transit?)

      {:ok, view, _html} = live(conn, ~p"/returns")

      assert has_element?(view, ~s{select[name="shipment_id"] option[value="#{landed.id}"]})
      refute has_element?(view, ~s{select[name="shipment_id"] option[value="#{rolling.id}"]})
    end
  end
end
