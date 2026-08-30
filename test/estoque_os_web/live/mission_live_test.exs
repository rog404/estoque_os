defmodule EstoqueOSWeb.MissionLiveTest do
  @moduledoc """
  The panel exists to keep four questions apart on screen: sent, returned, used,
  and donated. A report that collapses "used" and "given away" into "gone" is the
  reason a coordinator cannot answer an auditor, so the screen is tested for the
  distinction and not merely for rendering.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Missions, Outbound, Repo}
  alias EstoqueOS.Inventory.Location

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    gauze = product_fixture(%{name: "Gaze estéril"})
    lot = lot_fixture(%{product_id: gauze.id, expires_on: ~D[2028-01-31]})

    box = box_fixture(%{code: "ML01", location_id: warehouse.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: warehouse.id, box_id: box.id, quantity: Decimal.new(100)}
        ]
      })

    %{warehouse: warehouse, site: site, gauze: gauze, lot: lot, box: box}
  end

  defp with_mission(%{site: site}) do
    {:ok, mission} =
      Missions.create_mission(%{
        name: "Tefé 2026/1",
        location_id: site.id,
        starts_on: Date.utc_today(),
        ends_on: Date.add(Date.utc_today(), 7),
        tables: 4
      })

    mission
  end

  describe "index" do
    test "creates a mission and lists it", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/missions")

      html =
        view
        |> form("#new-mission", %{
          "name" => "Coari 2026/1",
          "location_id" => "#{site.id}",
          "starts_on" => "#{Date.utc_today()}",
          "ends_on" => "#{Date.add(Date.utc_today(), 7)}",
          "tables" => "6"
        })
        |> render_submit()

      assert html =~ "Coari 2026/1"
      assert html =~ "Missão Tefé"
    end

    test "a mission still out says so instead of showing a blank date", context do
      _mission = with_mission(context)

      {:ok, _view, html} = live(context.conn, ~p"/missions")

      assert html =~ "em curso"
    end

    test "creates the place along with the mission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/missions")

      html =
        view
        |> form("#new-mission", %{
          "name" => "Eirunepé 2026/2",
          "new_location_name" => "Missão Eirunepé",
          "starts_on" => "#{Date.utc_today()}",
          "ends_on" => "#{Date.add(Date.utc_today(), 7)}"
        })
        |> render_submit()

      # A mission usually goes somewhere the ONG has never been. Sending the
      # coordinator to another screen and back to register the place first is a
      # detour that invites a half-created mission.
      assert html =~ "Eirunepé 2026/2"
      assert html =~ "Missão Eirunepé"

      created =
        Repo.one!(from l in Location, where: l.name == "Missão Eirunepé")

      assert created.kind == "mission_site"
    end

    test "refuses to both pick a place and name one", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/missions")

      html =
        view
        |> form("#new-mission", %{
          "name" => "Ambíguo",
          "location_id" => "#{site.id}",
          "new_location_name" => "Missão Outra",
          "starts_on" => "#{Date.utc_today()}",
          "ends_on" => "#{Date.add(Date.utc_today(), 7)}"
        })
        |> render_submit()

      assert html =~ "não os dois"
      refute Repo.exists?(from l in Location, where: l.name == "Missão Outra")
    end

    test "asks where the mission goes when told neither", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/missions")

      html =
        view
        |> form("#new-mission", %{
          "name" => "Sem lugar",
          "starts_on" => "#{Date.utc_today()}",
          "ends_on" => "#{Date.add(Date.utc_today(), 7)}"
        })
        |> render_submit()

      assert html =~ "Diga para onde a missão vai"
    end

    test "refuses a mission that ends before it starts", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/missions")

      html =
        view
        |> form("#new-mission", %{
          "name" => "Impossível",
          "location_id" => "#{site.id}",
          "starts_on" => "2026-03-19",
          "ends_on" => "2026-03-12"
        })
        |> render_submit()

      assert html =~ "cannot be before the start"
      refute html =~ ~s(mission-)
    end

    test "offers only mission sites, never the warehouse", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/missions")

      # The picker decides where a load-out gets filed; a warehouse in it would
      # let somebody file the trip against the place it left from.
      assert html =~ "Missão Tefé"
      refute html =~ ">Estoque Principal<"
    end
  end

  describe "panel" do
    test "keeps used and donated apart", context do
      mission = with_mission(context)
      %{site: site, warehouse: warehouse, gauze: gauze} = context

      # Only boxes travel, so the box the stock sits in is what leaves.
      {:ok, _} =
        Outbound.load_out(%{
          source_location_id: warehouse.id,
          destination_location_id: site.id,
          box_ids: [context.box.id],
          user_id: actor_id()
        })

      {:ok, _} =
        Outbound.issue(gauze.id, 10, %{
          location_id: site.id,
          user_id: actor_id(),
          destination: "pacu"
        })

      {:ok, _} =
        Outbound.issue(gauze.id, 5, %{
          location_id: site.id,
          destination: "donation",
          recipient_name: "Hospital de Tefé",
          user_id: actor_id()
        })

      {:ok, _view, html} = live(context.conn, ~p"/missions/#{mission.id}")

      assert html =~ "Gaze estéril"
      assert html =~ "Usado"
      assert html =~ "Doado"

      # 100 sent, 10 used, 5 donated, nothing returned: 85 the ledger cannot place.
      assert html =~ "não consegue situar"
      # 10 used across 4 tables.
      assert html =~ "2,5 por mesa"
    end

    test "the return date can be moved after the trip was created", context do
      mission = with_mission(context)
      {:ok, view, _html} = live(context.conn, ~p"/missions/#{mission.id}")

      later = Date.add(Date.utc_today(), 21)

      html =
        view
        |> form("#mission-dates", %{
          "starts_on" => "#{mission.starts_on}",
          "ends_on" => "#{later}",
          "tables" => "6"
        })
        |> render_submit()

      # The flight home moves and the team stays an extra day. Nothing about the
      # movements changes.
      assert html =~ "Datas atualizadas"
      assert Missions.get_mission!(mission.id).ends_on == later
      assert Missions.get_mission!(mission.id).tables == 6
    end

    test "refuses a return date before the departure", context do
      mission = with_mission(context)
      {:ok, view, _html} = live(context.conn, ~p"/missions/#{mission.id}")

      html =
        view
        |> form("#mission-dates", %{
          "starts_on" => "#{Date.utc_today()}",
          "ends_on" => "#{Date.add(Date.utc_today(), -5)}"
        })
        |> render_submit()

      assert html =~ "cannot be before the start"
    end

    test "an untouched mission renders without inventing numbers", context do
      mission = with_mission(context)

      {:ok, _view, html} = live(context.conn, ~p"/missions/#{mission.id}")

      assert html =~ "Nada se movimentou nesta missão ainda"
      refute html =~ "não consegue situar"
    end

    test "says what is missing when nobody recorded the size", %{conn: conn, site: site} do
      {:ok, sizeless} =
        Missions.create_mission(%{
          name: "Sem mesas",
          location_id: site.id,
          starts_on: Date.utc_today(),
          ends_on: Date.add(Date.utc_today(), 7)
        })

      {:ok, _view, html} = live(conn, ~p"/missions/#{sizeless.id}")

      assert html =~ "informe o número de mesas"
    end
  end

  describe "donate before it expires" do
    # Puts something short-dated in the travelling box and sends it to the site.
    defp with_expiring_stock(context) do
      %{warehouse: warehouse, site: site, box: box} = context

      serum = product_fixture(%{name: "Soro fisiológico"})

      lot =
        lot_fixture(%{
          product_id: serum.id,
          lot_number: "L-2291",
          expires_on: Date.add(Date.utc_today(), 20)
        })

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(40)
            }
          ]
        })

      {:ok, _} =
        Outbound.load_out(%{
          source_location_id: warehouse.id,
          destination_location_id: site.id,
          box_ids: [box.id],
          user_id: actor_id()
        })

      %{serum: serum, serum_lot: lot}
    end

    test "lists what will not survive the trip home", context do
      mission = with_mission(context)
      %{serum_lot: lot} = with_expiring_stock(context)

      {:ok, _view, html} = live(context.conn, ~p"/missions/#{mission.id}")

      assert html =~ "Doar antes de vencer"
      assert html =~ "Soro fisiológico"
      assert html =~ "L-2291"
      assert html =~ "em 20 dia(s)"
      assert html =~ ~s(value="#{lot.id}")
    end

    test "carries the ticked lots to the write-off screen", context do
      mission = with_mission(context)
      %{serum_lot: lot} = with_expiring_stock(context)

      {:ok, view, _html} = live(context.conn, ~p"/missions/#{mission.id}")

      view
      |> form("#donation-picks", %{"lots" => ["#{lot.id}"]})
      |> render_change()

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("button", "Doar selecionados") |> render_click()

      assert to =~ "/issue?"
      assert to =~ "donate=#{lot.id}"
      assert to =~ "location=#{context.site.id}"

      {:ok, _issue, html} = live(context.conn, to)

      # The basket arrives filled: the whole position, the lot it came from, and
      # a donation already chosen. Typing none of that back in is the point.
      assert html =~ "Soro fisiológico"
      assert html =~ "L-2291"
      assert html =~ "40"
    end

    test "a stale link fills nothing rather than posting what is gone", context do
      _mission = with_mission(context)
      %{serum: serum, serum_lot: lot} = with_expiring_stock(context)

      {:ok, _} =
        Outbound.issue(serum.id, 40, %{
          location_id: context.site.id,
          user_id: actor_id(),
          destination: "pacu"
        })

      {:ok, _issue, html} =
        live(context.conn, ~p"/issue?donate=#{lot.id}&location=#{context.site.id}")

      assert html =~ "Esse estoque não está mais aqui"
    end

    test "stays off the screen when nothing is expiring", context do
      mission = with_mission(context)

      {:ok, _view, html} = live(context.conn, ~p"/missions/#{mission.id}")

      # Tags first: the words this panel is made of hide inside class names and
      # ids all over the page, and a refute that passes on markup protects
      # nothing.
      text = String.replace(html, ~r{<[^>]*>}s, " ")

      refute text =~ "Doar antes de vencer"
      refute text =~ "Doar selecionados"
    end
  end
end
