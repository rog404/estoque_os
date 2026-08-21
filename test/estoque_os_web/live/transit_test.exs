defmodule EstoqueOSWeb.TransitTest do
  @moduledoc """
  The load as a record, and the question it exists to answer: *quem está com a
  carga?*

  Before the shipment existed, the ledger could say some quantity sat at a
  location called Trânsito and nothing more. One bucket, so two loads travelling
  at once were indistinguishable, and nothing said with whom, since when, or
  expected where.
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

    %{warehouse: warehouse, transit: transit, box: box, lot: lot}
  end

  defp send_load(view, params) do
    view |> element("#load-form") |> render_submit(params)
  end

  describe "sending a load" do
    test "records who is carrying it, under which number, and when it is due", %{
      conn: conn,
      box: box,
      transit: transit,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{transit.id}",
        "carrier" => "STRALOG",
        "waybill" => "CTE-99182",
        "expected_arrival" => "#{Date.add(Date.utc_today(), 5)}"
      })

      assert [%Shipment{} = shipment] = Repo.all(Shipment) |> Repo.preload(:carrier)

      assert shipment.carrier.legal_name == "STRALOG"
      assert shipment.waybill == "CTE-99182"
      assert shipment.expected_arrival == Date.add(Date.utc_today(), 5)
      assert shipment.shipped_on == Date.utc_today()
      # Open, which is what "still out there" means. No status column to
      # disagree with itself.
      assert is_nil(shipment.received_at)
      assert shipment.sent_transaction_id
    end

    # "STRALOG" typed today and "Stralog" next month are one carrier, or nothing
    # can be asked about either of them. Same naming chaos SPEC §3.13 blames for
    # killing a previous system.
    test "the same carrier typed differently is the same carrier", %{
      conn: conn,
      box: box,
      transit: transit,
      warehouse: warehouse
    } do
      {:ok, _carrier} = Catalog.resolve_carrier("STRALOG")

      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{transit.id}",
        "carrier" => "  stralog "
      })

      assert length(Catalog.list_carriers()) == 1
    end

    test "a load the team carries itself is still a load", %{
      conn: conn,
      box: box,
      transit: transit,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{transit.id}",
        "carrier" => ""
      })

      # Refusing the trip because nobody was hired for it would lose the trip.
      assert [shipment] = Repo.all(Shipment)
      assert is_nil(shipment.carrier_id)
      assert Catalog.list_carriers() == []
    end
  end

  describe "the transit report" do
    setup %{conn: conn, box: box, transit: transit, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/load-out")

      send_load(view, %{
        "box_ids" => ["#{box.id}"],
        "source_id" => "#{warehouse.id}",
        "destination_id" => "#{transit.id}",
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
      assert html =~ "Trânsito"
      assert html =~ "1 carga(s) ainda na estrada"
    end

    test "shows nothing once the load is received", %{conn: conn, warehouse: warehouse} do
      [%{shipment: shipment}] = Outbound.open_shipments()

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

      # Posting its contents twice is exactly what the bracket exists to
      # prevent.
      assert {:error, :already_received} =
               Outbound.receive_shipment(closed, %{
                 destination_location_id: warehouse.id,
                 lines: lines,
                 user_id: actor_id()
               })
    end
  end
end
