defmodule EstoqueOS.MissionsTest do
  @moduledoc """
  A mission is the unit the coordinator answers for, and the four questions asked
  about it are different questions: what went out, what came back, what was used,
  and what was handed to the hospital at the end. Donated is not consumed — the
  goods still exist, they just belong to somebody else now.

  Movements are stamped when they happen rather than matched by date later. A
  mission whose dates shift after the fact must not silently reassign history.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Missions, Outbound}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    site = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    {:ok, mission} =
      Missions.create_mission(%{
        name: "Tefé 2026/1",
        location_id: site.id,
        starts_on: Date.utc_today(),
        ends_on: Date.add(Date.utc_today(), 7),
        tables: 4
      })

    gauze = product_fixture(%{name: "Gaze estéril"})
    lot = lot_fixture(%{product_id: gauze.id, expires_on: ~D[2028-01-31]})

    box = box_fixture(%{code: "MS01", location_id: warehouse.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: box.id,
            quantity: Decimal.new(100),
            unit_cost: Decimal.new("1.50")
          }
        ]
      })

    %{warehouse: warehouse, site: site, mission: mission, gauze: gauze, lot: lot, box: box}
  end

  # Only boxes travel, so the trip sends the box the stock sits in.
  defp send_out(%{warehouse: warehouse, site: site, box: box}) do
    {:ok, result} =
      Outbound.load_out(%{
        source_location_id: warehouse.id,
        destination_location_id: site.id,
        box_ids: [box.id],
        user_id: actor_id(),
        destination: "pacu"
      })

    result
  end

  describe "for_location/1" do
    test "finds the trip at a site", %{site: site, mission: mission} do
      assert Missions.for_location(site.id).id == mission.id
    end

    test "nothing at a warehouse", %{warehouse: warehouse} do
      refute Missions.for_location(warehouse.id)
    end

    test "dates do not gate it", %{site: site, mission: mission} do
      # A load-out gets prepared before the team flies, and a box comes home a
      # week after it was due. Both must land on this mission.
      {:ok, _} =
        Missions.update_mission(mission, %{
          starts_on: Date.add(Date.utc_today(), 30),
          ends_on: Date.add(Date.utc_today(), 37)
        })

      assert Missions.for_location(site.id).id == mission.id

      {:ok, _} =
        Missions.update_mission(Missions.get_mission!(mission.id), %{
          starts_on: Date.add(Date.utc_today(), -60),
          ends_on: Date.add(Date.utc_today(), -50)
        })

      assert Missions.for_location(site.id).id == mission.id
    end

    test "the open trip wins over the closed one before it", %{site: site, mission: mission} do
      {:ok, _} =
        Missions.update_mission(mission, %{
          starts_on: Date.add(Date.utc_today(), -35),
          ends_on: Date.add(Date.utc_today(), -30)
        })

      {:ok, open} =
        Missions.create_mission(%{
          name: "Tefé 2026/2",
          location_id: site.id,
          starts_on: Date.add(Date.utc_today(), -29),
          ends_on: Date.add(Date.add(Date.utc_today(), -29), 7)
        })

      # Trips at one place cannot overlap, so the open one is always the latest.
      assert Missions.for_location(site.id).id == open.id
    end

    test "with every trip closed, the most recent takes it", %{site: site, mission: mission} do
      {:ok, _} =
        Missions.update_mission(mission, %{
          starts_on: Date.add(Date.utc_today(), -35),
          ends_on: Date.add(Date.utc_today(), -30)
        })

      {:ok, newer} =
        Missions.create_mission(%{
          name: "Tefé 2026/2",
          location_id: site.id,
          starts_on: Date.utc_today(),
          ends_on: Date.utc_today()
        })

      assert Missions.for_location(site.id).id == newer.id
    end
  end

  describe "stamping" do
    test "a load-out to the site belongs to the mission", context do
      result = send_out(context)

      assert result.transaction.mission_id == context.mission.id
    end

    test "a load-out to a warehouse belongs to no mission", %{warehouse: warehouse, box: box} do
      other = location_fixture(%{name: "Escritório SP", kind: "warehouse"})

      {:ok, result} =
        Outbound.load_out(%{
          source_location_id: warehouse.id,
          destination_location_id: other.id,
          box_ids: [box.id],
          user_id: actor_id(),
          destination: "pacu"
        })

      refute result.transaction.mission_id
    end
  end

  describe "panel/1" do
    test "separates what came back from what was used and what was given away",
         %{mission: mission, site: site, warehouse: warehouse, lot: lot} = context do
      send_out(context)

      # Used during the mission.
      {:ok, _} =
        Outbound.issue(context.gauze.id, 10, %{
          location_id: site.id,
          user_id: actor_id(),
          destination: "pacu"
        })

      # Handed to the hospital at the end. Not consumed — it still exists.
      {:ok, _} =
        Outbound.issue(context.gauze.id, 5, %{
          location_id: site.id,
          destination: "donation",
          recipient_name: "Hospital de Tefé",
          user_id: actor_id()
        })

      {:ok, _} =
        Outbound.receive_return(%{
          source_location_id: site.id,
          destination_location_id: warehouse.id,
          lines: [
            %{
              lot_id: lot.id,
              from_box_id: context.box.id,
              quantity: Decimal.new(25),
              expected: Decimal.new(25)
            }
          ],
          user_id: actor_id()
        })

      panel = Missions.panel(Missions.get_mission!(mission.id))

      assert [line] = panel.lines
      assert Decimal.equal?(line.sent, Decimal.new(100))
      assert Decimal.equal?(line.returned, Decimal.new(25))
      assert Decimal.equal?(line.consumed, Decimal.new(10))
      assert Decimal.equal?(line.donated, Decimal.new(5))

      # 100 out, 25 back, 10 used, 5 given away: 60 still sitting at the site.
      assert Decimal.equal?(line.unaccounted, Decimal.new(60))
      assert Decimal.equal?(panel.totals.sent, Decimal.new(100))
      assert Decimal.equal?(panel.still_there, Decimal.new(60))
    end

    test "says so when the ledger cannot place everything", context do
      send_out(context)

      {:ok, _} =
        Outbound.issue(context.gauze.id, 10, %{
          location_id: context.site.id,
          user_id: actor_id(),
          destination: "pacu"
        })

      panel = Missions.panel(Missions.get_mission!(context.mission.id))

      # 90 are still sitting at the mission site with nothing said about them.
      assert [line] = panel.lines
      assert Decimal.equal?(line.unaccounted, Decimal.new(90))
      assert Decimal.equal?(panel.still_there, Decimal.new(90))
    end

    test "an untouched mission reports nothing rather than crashing", %{mission: mission} do
      panel = Missions.panel(Missions.get_mission!(mission.id))

      assert panel.lines == []
      assert Decimal.equal?(panel.totals.consumed, Decimal.new(0))
    end
  end

  describe "a mission that has already closed" do
    setup %{mission: mission} do
      {:ok, closed} =
        Missions.update_mission(mission, %{
          starts_on: Date.add(Date.utc_today(), -14),
          ends_on: Date.add(Date.utc_today(), -7)
        })

      %{closed: closed}
    end

    test "still owns the goods at its site", %{site: site, closed: closed} do
      assert Missions.for_location(site.id).id == closed.id
    end

    test "a return that arrives late still belongs to it", context do
      %{site: site, warehouse: warehouse, box: box, closed: closed} = context

      send_out(context)

      {:ok, _} =
        Outbound.receive_return(%{
          source_location_id: site.id,
          destination_location_id: warehouse.id,
          lines: [
            %{
              lot_id: context.lot.id,
              from_box_id: box.id,
              quantity: Decimal.new(60),
              expected: Decimal.new(100)
            }
          ],
          user_id: actor_id()
        })

      panel = Missions.panel(Missions.get_mission!(closed.id))

      # The flight is when the flight is. A box landing three days after the trip
      # closed must not read as never having come back.
      assert Decimal.equal?(panel.totals.returned, Decimal.new(60))
    end

    test "a new trip at the same site takes over", %{site: site} do
      {:ok, newer} =
        Missions.create_mission(%{
          name: "Tefé 2026/2",
          location_id: site.id,
          starts_on: Date.utc_today(),
          ends_on: Date.add(Date.utc_today(), 7)
        })

      assert Missions.for_location(site.id).id == newer.id
    end
  end

  describe "a box that goes straight to the next mission" do
    test "counts as moved on for the first, and as sent for the second", context do
      %{warehouse: warehouse, site: site, box: box} = context
      first = context.mission
      next_site = location_fixture(%{name: "Missão Coari", kind: "mission_site"})

      {:ok, second} =
        Missions.create_mission(%{
          name: "Coari 2026/1",
          location_id: next_site.id,
          starts_on: Date.utc_today(),
          ends_on: Date.add(Date.utc_today(), 7),
          tables: 2
        })

      send_out(context)

      {:ok, _} =
        Outbound.issue(context.gauze.id, 10, %{
          location_id: site.id,
          user_id: actor_id(),
          destination: "pacu"
        })

      # Straight on to the next city without coming home.
      {:ok, _} =
        Outbound.load_out(%{
          source_location_id: site.id,
          destination_location_id: next_site.id,
          box_ids: [box.id],
          user_id: actor_id(),
          destination: "pacu"
        })

      first_panel = Missions.panel(Missions.get_mission!(first.id))
      second_panel = Missions.panel(Missions.get_mission!(second.id))

      # 100 arrived, 10 used, 90 went on. Nothing is unaccounted for — the goods
      # are not lost, they are at the next mission.
      assert Decimal.equal?(first_panel.totals.sent, Decimal.new(100))
      assert Decimal.equal?(first_panel.totals.consumed, Decimal.new(10))
      assert Decimal.equal?(first_panel.totals.handed_on, Decimal.new(90))
      assert Decimal.equal?(first_panel.totals.unaccounted, Decimal.new(0))

      assert Decimal.equal?(second_panel.totals.sent, Decimal.new(90))
      assert Decimal.equal?(second_panel.totals.handed_on, Decimal.new(0))
      refute is_nil(warehouse)
    end

    test "a load-out from the warehouse hands nothing on", context do
      send_out(context)

      panel = Missions.panel(Missions.get_mission!(context.mission.id))

      assert Decimal.equal?(panel.totals.handed_on, Decimal.new(0))
    end
  end

  describe "consumption_per_table/1" do
    test "divides by the size somebody recorded", context do
      send_out(context)

      {:ok, _} =
        Outbound.issue(context.gauze.id, 12, %{
          location_id: context.site.id,
          user_id: actor_id(),
          destination: "pacu"
        })

      panel = Missions.panel(Missions.get_mission!(context.mission.id))

      assert Decimal.equal?(Missions.consumption_per_table(panel), Decimal.new("3.00"))
    end

    test "refuses to invent a figure when nobody recorded the size", %{site: site} do
      {:ok, sizeless} =
        Missions.create_mission(%{
          name: "Coari 2026/1",
          location_id: site.id,
          starts_on: Date.add(Date.utc_today(), -60),
          ends_on: Date.add(Date.utc_today(), -50)
        })

      assert is_nil(Missions.consumption_per_table(Missions.panel(sizeless)))
    end
  end

  describe "create_mission/1" do
    test "refuses to end before it starts", %{site: site} do
      assert {:error, changeset} =
               Missions.create_mission(%{
                 name: "Impossível",
                 location_id: site.id,
                 starts_on: ~D[2026-03-19],
                 ends_on: ~D[2026-03-12]
               })

      assert "cannot be before the start" in errors_on(changeset).ends_on
    end

    test "refuses a duplicate name", %{} do
      # Somewhere else, so the name is the only thing that can be wrong.
      elsewhere = location_fixture(%{name: "Missão Outra", kind: "mission_site"})

      assert {:error, changeset} =
               Missions.create_mission(%{
                 name: "tefé 2026/1",
                 location_id: elsewhere.id,
                 starts_on: Date.utc_today(),
                 ends_on: Date.add(Date.utc_today(), 7)
               })

      assert errors_on(changeset).name
    end
  end

  describe "one trip at a time in one place" do
    test "refuses a second mission overlapping at the same site", %{site: site} do
      assert {:error, changeset} =
               Missions.create_mission(%{
                 name: "Tefé 2026/2",
                 location_id: site.id,
                 starts_on: Date.utc_today(),
                 ends_on: Date.add(Date.utc_today(), 7)
               })

      assert "overlaps another mission at this place" in errors_on(changeset).starts_on
    end

    test "allows the same dates somewhere else — even another country", %{warehouse: _w} do
      abroad = location_fixture(%{name: "Missão Cabo Delgado", kind: "mission_site"})

      # Nothing about a mission is specific to one country: it is a place and a
      # pair of dates, and the operation can be in two of them at once.
      assert {:ok, _} =
               Missions.create_mission(%{
                 name: "Cabo Delgado 2026/1",
                 location_id: abroad.id,
                 starts_on: Date.utc_today(),
                 ends_on: Date.add(Date.utc_today(), 7)
               })
    end

    test "allows the next trip once the last one closed", %{site: site, mission: mission} do
      {:ok, _} =
        Missions.update_mission(mission, %{
          starts_on: Date.add(Date.utc_today(), -20),
          ends_on: Date.add(Date.utc_today(), -10)
        })

      assert {:ok, _} =
               Missions.create_mission(%{
                 name: "Tefé 2026/2",
                 location_id: site.id,
                 starts_on: Date.add(Date.utc_today(), -9),
                 ends_on: Date.add(Date.add(Date.utc_today(), -9), 7)
               })
    end

    test "a later trip at the same place is fine once the dates clear", %{site: site} do
      # Every trip is bounded now, so a place is only blocked for the days it is
      # actually occupied. A year later is free.
      assert {:ok, _} =
               Missions.create_mission(%{
                 name: "Tefé 2027/1",
                 location_id: site.id,
                 starts_on: Date.add(Date.utc_today(), 365),
                 ends_on: Date.add(Date.utc_today(), 372)
               })
    end

    test "editing a mission does not collide with itself", %{mission: mission} do
      assert {:ok, _} = Missions.update_mission(mission, %{tables: 6})
    end

    test "the database refuses it even when two are created at once", %{site: site} do
      # The Elixir check cannot see a concurrent insert; the exclusion constraint
      # is the actual guarantee. Bypassing the changeset proves it is there.
      assert_raise Postgrex.Error, ~r/missions_must_not_overlap_at_a_place/, fn ->
        Repo.insert_all("missions", [
          %{
            name: "Fantasma",
            location_id: site.id,
            starts_on: Date.utc_today(),
            ends_on: Date.add(Date.utc_today(), 3),
            inserted_at: DateTime.utc_now(:second),
            updated_at: DateTime.utc_now(:second)
          }
        ])
      end
    end
  end

  describe "donation_candidates/1" do
    test "suggests what is at the site and about to expire", context do
      %{warehouse: warehouse, site: site, mission: mission, box: box} = context

      soon = product_fixture(%{name: "Soro fisiológico"})

      soon_lot =
        lot_fixture(%{
          product_id: soon.id,
          lot_number: "L-2291",
          expires_on: Date.add(Date.utc_today(), 20)
        })

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: soon_lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(40)
            }
          ]
        })

      send_out(context)

      candidates = Missions.donation_candidates(mission)

      assert [%{lot_id: lot_id, product: "Soro fisiológico", quantity: quantity}] = candidates
      assert lot_id == soon_lot.id
      assert Decimal.equal?(quantity, Decimal.new(40))

      # The gauze travelled in the same box and is at the same place. It expires
      # in 2028, so flying it home costs nothing — suggesting it would train the
      # coordinator to ignore the panel.
      refute Enum.any?(candidates, &(&1.product == "Gaze estéril"))
      assert site.id == mission.location_id
    end

    test "ignores stock that never left the warehouse", context do
      %{warehouse: warehouse, mission: mission, box: box} = context

      near = product_fixture(%{name: "Luva cirúrgica"})
      near_lot = lot_fixture(%{product_id: near.id, expires_on: Date.add(Date.utc_today(), 10)})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: near_lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(60)
            }
          ]
        })

      # No load-out: the box is still home, where the warehouse's own expiry
      # alert already covers it. A mission cannot donate what it does not have.
      assert Missions.donation_candidates(mission) == []
    end

    test "honours the per-product window", context do
      %{warehouse: warehouse, mission: mission, box: box} = context

      # Default window is 90 days. This one is 150 days out, so it is only a
      # candidate because the product asks for more warning than the rest.
      patient = product_fixture(%{name: "Insulina", expiry_alert_days_override: 200})

      patient_lot =
        lot_fixture(%{product_id: patient.id, expires_on: Date.add(Date.utc_today(), 150)})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: patient_lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(5)
            }
          ]
        })

      send_out(context)

      assert [%{product: "Insulina"}] = Missions.donation_candidates(mission)
    end
  end

  describe "list_mission_sites/0" do
    test "offers only mission sites, never a warehouse", %{site: site} do
      names = Missions.list_mission_sites() |> Enum.map(& &1.name)

      assert site.name in names
      refute "Estoque Principal" in names
    end
  end
end
