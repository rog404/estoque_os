defmodule EstoqueOSWeb.TransportDeclarationTest do
  @moduledoc """
  The paper that travels with a load.

  The carrier asks for a declaration of what is inside, who sends it and who
  receives it. It used to be typed in Word for every trip, with the item list
  copied out of this system by hand — so what is pinned here is that the list on
  the paper is the ledger's list, and that the recipient written on a signed
  document is not rewritten later by a change to the location.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}

  setup :register_and_log_in_operator

  setup %{conn: conn} do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    location_fixture(%{name: "Trânsito", kind: "transit"})
    mission = location_fixture(%{name: "Missão Porto Velho", kind: "mission_site"})
    box = box_fixture(%{code: "TR01", location_id: warehouse.id})

    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    glove = product_fixture(%{name: "Luva cirúrgica 7,5"})

    receive_into(gauze, warehouse, box, 300, "1.20")
    receive_into(glove, warehouse, box, 24, nil)

    {:ok, view, _html} = live(conn, ~p"/load-out")

    view
    |> element("#load-form")
    |> render_submit(%{
      "box_ids" => ["#{box.id}"],
      "source_id" => "#{warehouse.id}",
      "destination_id" => "#{mission.id}",
      "carrier" => "STRALOG",
      "waybill" => "CTE-99182"
    })

    [shipment] = Enum.map(Outbound.open_shipments(), & &1.shipment)

    %{shipment: shipment, mission: mission}
  end

  defp receive_into(product, location, box, quantity, cost) do
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            box_id: box.id,
            location_id: location.id,
            quantity: Decimal.new(quantity),
            unit_cost: cost && Decimal.new(cost)
          }
        ]
      })
  end

  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  defp fill(view, params) do
    view |> form("#declaration-form", %{"declaration" => params}) |> render_submit()
  end

  @recipient %{
    "recipient_name" => "Hospital de Base Dr. Ary Pinheiro",
    "recipient_document" => "04.287.520/0002-69",
    "recipient_address" => "Av. Governador Jorge Teixeira, 3766 - Porto Velho - RO",
    "recipient_postal_code" => "76821-092",
    "scheduling_code" => "AG-4471",
    "invoice_number" => "962667",
    "reference" => "2026/04",
    "issued_on" => "2026-04-01"
  }

  test "opens with what the load already knows filled in", %{conn: conn, shipment: shipment} do
    {:ok, _view, html} = live(conn, ~p"/shipments/#{shipment.id}/declaracao")

    assert html =~ "Missão Porto Velho"
    assert text(html) =~ "Compressa de gaze"
    assert text(html) =~ "Luva cirúrgica"
  end

  # The list is the ledger's, not a second one typed by hand: that is the whole
  # reason this screen exists.
  test "prints the goods the load actually carried", %{conn: conn, shipment: shipment} do
    {:ok, view, _html} = live(conn, ~p"/shipments/#{shipment.id}/declaracao")
    fill(view, @recipient)

    paper =
      text(get(conn, ~p"/shipments/#{shipment.id}/declaracao/imprimir") |> html_response(200))

    assert paper =~ "Declaração de conteúdo"
    assert paper =~ "Hospital de Base Dr. Ary Pinheiro"
    assert paper =~ "04.287.520/0002-69"
    assert paper =~ "Compressa de gaze"
    assert paper =~ "300"
    assert paper =~ "TR01"
    assert paper =~ "AG-4471"
    assert paper =~ "962667"
  end

  # A donated lot has no cost, and a value that quietly counted it as zero would
  # declare a number that is not the goods' worth.
  test "says how many lines carry no value", %{conn: conn, shipment: shipment} do
    {:ok, view, _html} = live(conn, ~p"/shipments/#{shipment.id}/declaracao")
    fill(view, @recipient)

    paper =
      text(get(conn, ~p"/shipments/#{shipment.id}/declaracao/imprimir") |> html_response(200))

    assert paper =~ "R$ 360,00"
    assert paper =~ "1 item(ns) recebido(s) como doação"
  end

  # One paper per load. A second declaration for the same goods is the situation
  # where two signed documents disagree about what travelled.
  test "rewriting fills the same paper in again", %{conn: conn, shipment: shipment} do
    {:ok, view, _html} = live(conn, ~p"/shipments/#{shipment.id}/declaracao")
    fill(view, @recipient)
    first = Outbound.get_declaration(shipment)

    {:ok, view, _html} = live(conn, ~p"/shipments/#{shipment.id}/declaracao")
    fill(view, Map.put(@recipient, "scheduling_code", "AG-5000"))

    second = Outbound.get_declaration(shipment)

    assert second.id == first.id
    assert second.scheduling_code == "AG-5000"
  end

  # The registration is what was declared on the day. A location renamed next
  # month must not rewrite a document already signed.
  test "keeps the recipient it was written with", %{
    conn: conn,
    shipment: shipment,
    mission: mission
  } do
    {:ok, view, _html} = live(conn, ~p"/shipments/#{shipment.id}/declaracao")
    fill(view, @recipient)

    {:ok, _} = EstoqueOS.Inventory.Locations.update_location(mission, %{name: "Missão PVH 2027"})

    paper =
      text(get(conn, ~p"/shipments/#{shipment.id}/declaracao/imprimir") |> html_response(200))

    assert paper =~ "Hospital de Base Dr. Ary Pinheiro"
    refute paper =~ "Missão PVH 2027"
  end

  # A blank sheet with the ONG's letterhead is a document waiting to say
  # something untrue.
  test "refuses to print a declaration nobody wrote", %{conn: conn, shipment: shipment} do
    conn = get(conn, ~p"/shipments/#{shipment.id}/declaracao/imprimir")

    assert redirected_to(conn) == ~p"/shipments/#{shipment.id}/declaracao"
  end
end
