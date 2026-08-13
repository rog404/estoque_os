# A development scenario, on top of the real catalog.
#
#     mix ecto.reset && mix dev.seeds
#
# `seeds.exs` loads the truth a fresh install has: the locations, the 322 lines
# of the OSI standard supply table, and the five kits. It creates no stock, which
# is correct — a new install has none.
#
# This file creates two years of operating history, because the screens that
# matter most are the ones that compare: a mission panel with a single mission in
# it teaches nothing, and "below minimum" means nothing without something having
# been used up.
#
# What it builds:
#
#   * one warehouse, "Principal", with ten boxes
#   * medical supply in lots that expire on a spread, a few already expired
#   * office equipment and stationery, which travel from mission to mission and
#     are never issued
#   * six missions across two years — most of a week, two of them a weekend —
#     each averaging 28 surgeries
#   * five of them closed, with their load-out, consumption, donation and return
#   * one under way right now, so the live screens have something to show
#   * a handful of products left short, so the shortage list is short enough to
#     act on
#
# The five closed missions are written straight to the ledger with their real
# dates. The outbound flows stamp `mission_id` from the clock, which is right for
# an operator standing in the warehouse and wrong for a seed writing history — so
# history is constructed, and only the mission under way goes through the flows
# the screens use.
#
# Refuses to run twice: running it again would silently double every balance.

import Ecto.Query

alias EstoqueOS.Catalog
alias EstoqueOS.Catalog.Product
alias EstoqueOS.Inventory
alias EstoqueOS.Inventory.{Box, Location, Locations, Lot, StockSnapshot}
alias EstoqueOS.{Kits, Missions, Outbound, Repo}

today = Date.utc_today()

if Repo.exists?(from b in Box, where: b.code == "PR01") do
  IO.puts("""

  The scenario is already loaded (box PR01 exists).

  Running again would double every balance, so this stops here. To rebuild it:

      mix ecto.reset && mix dev.seeds
  """)

  System.halt(0)
end

## Who

user =
  case Repo.one(from u in EstoqueOS.Accounts.User, limit: 1) do
    nil ->
      {:ok, created} = EstoqueOS.Accounts.register_user(%{email: "dev@estoque.local"})
      {:ok, admin} = EstoqueOS.Accounts.update_user_role(created, "admin")

      admin
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
      |> Repo.update!()

    found ->
      found
  end

user_id = user.id

## Where
#
# One warehouse, because that is what the scenario is about. The locations
# `seeds.exs` ships are deactivated rather than deleted: transactions name the
# location they moved stock from, and `default_location/0` falls through to the
# first active warehouse, which is this one.

{:ok, warehouse} =
  case Repo.get_by(Location, name: "Principal") do
    nil -> Locations.create_location(%{name: "Principal", kind: "warehouse"})
    found -> {:ok, found}
  end

Location
|> where([l], l.kind == "warehouse" and l.id != ^warehouse.id)
|> Repo.update_all(set: [active: false, updated_at: DateTime.utc_now(:second)])

transit =
  Repo.get_by(Location, kind: "transit") ||
    elem(Locations.create_location(%{name: "Trânsito", kind: "transit"}), 1)

mission_site = fn name ->
  case Repo.get_by(Location, name: name) do
    nil -> elem(Locations.create_location(%{name: name, kind: "mission_site"}), 1)
    found -> found
  end
end

## Boxes
#
# Ten, and one of them is the office box: the printer, the scanner and the
# stationery live in it and travel with every mission. Nothing in it is ever
# issued — it goes out and comes back, which is exactly why it must be a box.

boxes =
  for n <- 1..10 do
    code = "PR#{String.pad_leading("#{n}", 2, "0")}"
    {:ok, box} = Locations.create_box(%{code: code, location_id: warehouse.id})
    box
  end

office_box = List.last(boxes)
supply_boxes = Enum.take(boxes, 9)

## Office equipment and stationery
#
# Answering the question this raised: they are ordinary products, not a new
# concept. What separates them is `sector` and `expiry_expected` — paper does not
# expire, and a scanner missing an expiry date is not an alarm.
#
# A printer is arguably a different thing entirely: it has a serial number and
# the question asked of it is "where is it", not "how many". The model can carry
# that (one lot per unit, serial as the lot number) and the reports will still
# read it as stock. Good enough for a prototype; a real asset register is its own
# feature.

office_items = [
  {"Impressora multifuncional", "UN", 2, false},
  {"Scanner portátil", "UN", 2, false},
  {"Papel A4 (resma)", "RESMA", 20, false},
  {"Caneta esferográfica azul", "UN", 50, false},
  {"Lápis preto", "UN", 50, false}
]

office_products =
  for {name, unit, quantity, expiry?} <- office_items do
    {:ok, product} =
      Catalog.create_product(%{
        name: name,
        stock_unit: unit,
        sector: "ESCRITÓRIO",
        expiry_expected: expiry?,
        min_stock_override: Decimal.new(quantity)
      })

    {product, quantity}
  end

## Medical supply
#
# Drawn from the real catalog rather than invented, so the names on screen are
# the names the operation uses. Expiry is spread on purpose: a few already past,
# a few inside the alert window, most comfortable.

supply_products =
  Product
  |> where([p], p.active and is_nil(p.sector) == false and p.sector != "ESCRITÓRIO")
  |> order_by([p], asc: p.id)
  |> limit(40)
  |> Repo.all()

expiry_for = fn index ->
  cond do
    # A few genuinely expired, which the dashboard must surface.
    index < 3 -> Date.add(today, -30 * (index + 1))
    # A few inside the alert window.
    index < 8 -> Date.add(today, 20 * (index - 2))
    # The rest comfortable.
    true -> Date.add(today, 200 + index * 30)
  end
end

supply_lots =
  supply_products
  |> Enum.with_index()
  |> Enum.map(fn {product, index} ->
    {:ok, lot} =
      %Lot{}
      |> Lot.changeset(%{
        product_id: product.id,
        lot_number: "L#{2000 + index}",
        expires_on: expiry_for.(index)
      })
      |> Repo.insert()

    {product, lot}
  end)

office_lots =
  for {product, quantity} <- office_products do
    {:ok, lot} =
      %Lot{}
      |> Lot.changeset(%{product_id: product.id, lot_number: nil, needs_review: false})
      |> Repo.insert()

    {product, lot, quantity}
  end

## The opening stock
#
# Everything lands in a box. Loose stock is a real state — goods that arrived and
# nobody has conferred yet — but it cannot travel, so a scenario that opens with
# it would have nothing to send.

post = fn attrs ->
  case Inventory.post_transaction(attrs) do
    {:ok, transaction} -> {:ok, transaction}
    {:error, reason} -> {:error, reason}
  end
end

opening_entries =
  supply_lots
  |> Enum.with_index()
  |> Enum.map(fn {{_product, lot}, index} ->
    %{
      lot_id: lot.id,
      location_id: warehouse.id,
      box_id: Enum.at(supply_boxes, rem(index, length(supply_boxes))).id,
      quantity: 400 + rem(index * 37, 300),
      unit_cost: Decimal.new("#{rem(index, 30) + 2}.#{String.pad_leading("#{rem(index * 7, 100)}", 2, "0")}")
    }
  end)

office_entries =
  Enum.map(office_lots, fn {_product, lot, quantity} ->
    %{
      lot_id: lot.id,
      location_id: warehouse.id,
      box_id: office_box.id,
      quantity: quantity,
      unit_cost: Decimal.new("15.00")
    }
  end)

{:ok, _} =
  post.(%{
    type: "purchase_in",
    user_id: user_id,
    occurred_at: DateTime.new!(Date.add(today, -400), ~T[09:00:00]),
    notes: "Estoque inicial",
    entries: opening_entries ++ office_entries
  })

## The missions
#
# Six across two years. A mission is usually a week; a couple are a weekend,
# which is the shorter format the operation also runs. 28 surgeries is the
# average, and consumption is scaled from it — a weekend mission does fewer.

mission_plan = [
  {"Tefé", -400, 7, 31},
  {"Coari", -330, 3, 12},
  {"Parintins", -250, 7, 29},
  {"Eirunepé", -170, 7, 26},
  {"Carauari", -95, 3, 14},
  {"Manacapuru", -14, 7, 28}
]

surgeries_note = fn count -> "#{count} cirurgias" end

# A closed mission, written straight to the ledger with its real dates: goods
# leave in boxes, some are used, some are handed to the hospital, the rest comes
# back. The office box always returns whole — that is the point of it.
close_mission = fn {city, offset, days, surgeries}, hold_office?, carried_from ->
  site = mission_site.("Missão #{city}")
  left_on = Date.add(today, offset)
  back_on = Date.add(left_on, days)

  {:ok, mission} =
    Missions.create_mission(%{
      name: "#{city} #{left_on.year}/#{if left_on.month <= 6, do: 1, else: 2}",
      location_id: site.id,
      starts_on: left_on,
      ends_on: back_on,
      tables: if(days <= 3, do: 2, else: 4),
      notes: surgeries_note.(surgeries)
    })

  travelling = Enum.take(supply_lots, 12)

  sent =
    Enum.with_index(travelling)
    |> Enum.map(fn {{_product, lot}, index} ->
      %{lot: lot, quantity: Decimal.new(surgeries * (2 + rem(index, 4)))}
    end)

  # The office box goes on every trip and comes back whole. Nothing in it is ever
  # issued — that is the whole distinction between equipment and supply, and it
  # only holds up if the box actually makes the round trip.
  office_positions =
    StockSnapshot
    |> where([s], s.box_id == ^office_box.id and s.location_id == ^warehouse.id and s.quantity > 0)
    |> select([s], %{lot_id: s.lot_id, quantity: s.quantity})
    |> Repo.all()

  # Out
  {:ok, _} =
    post.(%{
      type: "load_out",
      user_id: user_id,
      mission_id: mission.id,
      source_location_id: warehouse.id,
      destination_location_id: site.id,
      occurred_at: DateTime.new!(left_on, ~T[07:00:00]),
      notes: "Derrubada para #{mission.name}",
      entries:
        Enum.flat_map(Enum.with_index(sent), fn {%{lot: lot, quantity: quantity}, index} ->
          box = Enum.at(supply_boxes, rem(index, length(supply_boxes)))

          [
            %{lot_id: lot.id, location_id: warehouse.id, box_id: box.id, quantity: Decimal.negate(quantity)},
            %{lot_id: lot.id, location_id: site.id, box_id: box.id, quantity: quantity}
          ]
        end) ++
          Enum.flat_map(office_positions, fn row ->
            [
              %{lot_id: row.lot_id, location_id: warehouse.id, box_id: office_box.id, quantity: Decimal.negate(row.quantity)},
              %{lot_id: row.lot_id, location_id: site.id, box_id: office_box.id, quantity: row.quantity}
            ]
          end)
    })

  # Sometimes the previous trip's box comes straight here rather than going home
  # first. That is what the panel's "moved on" column exists for: the goods are
  # not lost, they are at the next mission.
  if carried_from do
    {from_mission, from_site_id} = carried_from

    carried =
      StockSnapshot
      |> where([s], s.location_id == ^from_site_id and s.quantity > 0)
      |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
      |> Repo.all()

    if carried != [] do
      {:ok, _} =
        post.(%{
          type: "load_out",
          user_id: user_id,
          mission_id: mission.id,
          source_mission_id: from_mission.id,
          source_location_id: from_site_id,
          destination_location_id: site.id,
          occurred_at: DateTime.new!(left_on, ~T[06:00:00]),
          notes: "Seguiu direto de #{from_mission.name}",
          entries:
            Enum.flat_map(carried, fn row ->
              [
                %{lot_id: row.lot_id, location_id: from_site_id, box_id: row.box_id, quantity: Decimal.negate(row.quantity)},
                %{lot_id: row.lot_id, location_id: site.id, box_id: row.box_id, quantity: row.quantity}
              ]
            end)
        })
    end
  end

  # Used during the mission, scaled by how many surgeries happened.
  {:ok, _} =
    post.(%{
      type: "manual_out",
      user_id: user_id,
      mission_id: mission.id,
      source_location_id: site.id,
      destination: "operating_room",
      occurred_at: DateTime.new!(Date.add(left_on, 2), ~T[14:00:00]),
      notes: "Consumo em #{surgeries} cirurgias",
      entries:
        Enum.with_index(sent)
        |> Enum.map(fn {%{lot: lot, quantity: quantity}, index} ->
          box = Enum.at(supply_boxes, rem(index, length(supply_boxes)))
          used = quantity |> Decimal.mult(Decimal.new("0.55")) |> Decimal.round(0)

          %{lot_id: lot.id, location_id: site.id, box_id: box.id, quantity: Decimal.negate(used)}
        end)
    })

  # Handed to the hospital at the end. Not consumed — it still exists.
  {:ok, _} =
    post.(%{
      type: "manual_out",
      user_id: user_id,
      mission_id: mission.id,
      source_location_id: site.id,
      destination: "donation",
      recipient_name: "Hospital de #{city}",
      occurred_at: DateTime.new!(back_on, ~T[16:00:00]),
      notes: "Termo de doação ao fim da missão",
      entries:
        Enum.with_index(Enum.take(sent, 4))
        |> Enum.map(fn {%{lot: lot, quantity: quantity}, index} ->
          box = Enum.at(supply_boxes, rem(index, length(supply_boxes)))
          given = quantity |> Decimal.mult(Decimal.new("0.15")) |> Decimal.round(0)

          %{lot_id: lot.id, location_id: site.id, box_id: box.id, quantity: Decimal.negate(given)}
        end)
    })

  # What is left comes home. The exception is the chain: sometimes a box goes
  # straight to the next city, and the panel has to read that as "moved on"
  # rather than as loss. `Coari` receives Tefé's office box without it passing
  # through the warehouse.
  remaining =
    StockSnapshot
    |> where([s], s.location_id == ^site.id and s.quantity > 0)
    |> then(fn query ->
      if hold_office?, do: where(query, [s], s.box_id != ^office_box.id), else: query
    end)
    |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
    |> Repo.all()

  if remaining != [] do
    {:ok, _} =
      post.(%{
        type: "return_in",
        user_id: user_id,
        mission_id: mission.id,
        source_location_id: site.id,
        destination_location_id: warehouse.id,
        occurred_at: DateTime.new!(Date.add(back_on, 1), ~T[11:00:00]),
        notes: "Retorno de #{mission.name}",
        entries:
          Enum.flat_map(remaining, fn row ->
            [
              %{lot_id: row.lot_id, location_id: site.id, box_id: row.box_id, quantity: Decimal.negate(row.quantity)},
              %{lot_id: row.lot_id, location_id: warehouse.id, box_id: row.box_id, quantity: row.quantity}
            ]
          end)
      })
  end

  mission
end

{closed, _carry} =
  mission_plan
  |> Enum.take(5)
  |> Enum.with_index()
  |> Enum.reduce({[], nil}, fn {plan, index}, {acc, carry} ->
    hold_office? = index == 0
    mission = close_mission.(plan, hold_office?, carry)
    next_carry = if hold_office?, do: {mission, mission.location_id}, else: nil

    {acc ++ [mission], next_carry}
  end)

## The mission under way
#
# This one goes through the real flows, so the live screens — load-out, return,
# the mission panel's warning line — have something honest to show. It is
# deliberately left open: the goods are at the site, nothing has come back.

{city, offset, days, surgeries} = List.last(mission_plan)
current_site = mission_site.("Missão #{city}")
left_on = Date.add(today, offset)

{:ok, current} =
  Missions.create_mission(%{
    name: "#{city} #{left_on.year}/2",
    location_id: current_site.id,
    starts_on: left_on,
    # Planned, not yet happened: the team is still there.
    ends_on: Date.add(left_on, days),
    tables: 4,
    notes: surgeries_note.(surgeries)
  })

travelling_boxes = Enum.take(supply_boxes, 4) ++ [office_box]

load_out_result =
  Outbound.load_out(%{
    source_location_id: warehouse.id,
    destination_location_id: current_site.id,
    box_ids: Enum.map(travelling_boxes, & &1.id),
    user_id: user_id,
    notes: "Derrubada para #{current.name}"
  })

# Some of it already used on site, so the panel is not all zeroes.
used_on_site =
  StockSnapshot
  |> where([s], s.location_id == ^current_site.id and s.quantity > 20)
  |> limit(6)
  |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
  |> Repo.all()

consumption_result =
  case used_on_site do
    [] ->
      {:error, "nothing reached the mission"}

    positions ->
      {:ok, _} =
        post.(%{
          type: "manual_out",
          user_id: user_id,
          mission_id: current.id,
          source_location_id: current_site.id,
          destination: "operating_room",
          notes: "Consumo em andamento",
          entries:
            Enum.map(positions, fn row ->
              %{
                lot_id: row.lot_id,
                location_id: current_site.id,
                box_id: row.box_id,
                quantity: row.quantity |> Decimal.mult(Decimal.new("0.3")) |> Decimal.round(0) |> Decimal.negate()
              }
            end)
        })

      {:ok, "#{length(positions)} positions drawn on at #{current_site.name}"}
  end

## Something to be short of
#
# A shortage list that lists everything is a list nobody reads. Three products
# are written down below the minimum a mission is expected to carry; the rest
# stay comfortable.

short_result =
  supply_lots
  |> Enum.drop(20)
  |> Enum.take(3)
  |> Enum.map(fn {product, lot} ->
    balance = Inventory.balance(lot_id: lot.id, location_id: warehouse.id)
    minimum = product.min_stock_override || Decimal.new(50)

    if Decimal.compare(balance, 0) == :gt do
      box =
        StockSnapshot
        |> where([s], s.lot_id == ^lot.id and s.location_id == ^warehouse.id and s.quantity > 0)
        |> limit(1)
        |> select([s], s.box_id)
        |> Repo.one()

      take = Decimal.sub(balance, Decimal.min(minimum, balance) |> Decimal.mult(Decimal.new("0.4")))

      post.(%{
        type: "adjustment",
        user_id: user_id,
        reason_code: "count_correction",
        notes: "Ajuste de contagem — cenário de falta",
        entries: [
          %{lot_id: lot.id, location_id: warehouse.id, box_id: box, quantity: Decimal.negate(take)}
        ]
      })
    end
  end)
  |> Enum.count(&match?({:ok, _}, &1))

## Report

IO.puts("\n=== what was created ===")
IO.puts("  warehouse:        #{warehouse.name} (others deactivated)")
IO.puts("  boxes:            #{length(boxes)} (#{office_box.code} is the office box)")
IO.puts("  supply products:  #{length(supply_lots)}")
IO.puts("  office products:  #{length(office_products)}")
IO.puts("  missions closed:  #{length(closed)}")
IO.puts("  mission open:     #{current.name} (#{days} days, #{surgeries} cirurgias)")

IO.puts(
  "  load-out:         " <>
    case load_out_result do
      {:ok, %{boxes_moved: moved}} -> "#{moved} boxes to #{current_site.name}"
      other -> "SKIPPED — #{inspect(other)}"
    end
)

IO.puts(
  "  on-site use:      " <>
    case consumption_result do
      {:ok, detail} -> detail
      {:error, reason} -> "SKIPPED — #{reason}"
    end
)

IO.puts("  short products:   #{short_result}")


expired =
  Repo.aggregate(
    from(s in StockSnapshot,
      join: l in Lot,
      on: l.id == s.lot_id,
      where: s.quantity != 0 and l.expires_on < ^today
    ),
    :count
  )

expiring =
  Repo.aggregate(
    from(s in StockSnapshot,
      join: l in Lot,
      on: l.id == s.lot_id,
      where: s.quantity != 0 and l.expires_on >= ^today and l.expires_on <= ^Date.add(today, 90)
    ),
    :count
  )

## Counts
#
# Until now no box had ever been counted, so every position on the stock screen
# said "presumido · nunca contada" — and a mark that is on every row is a mark
# that tells you nothing. The screen's whole claim is that it separates what was
# counted from what is inherited, and it could not demonstrate that claim.
#
# Counted last, because a count is a point in time and this is the state the
# demo opens on. Moving a box deliberately does not reset it: a box travels
# whole and is not recounted on arrival, which is why the ones that went to the
# mission are the ones nobody has verified.
#
# Written straight to the column, like the closed missions above it. The app's
# `mark_box_verified/1` stamps *now*, and "counted 48 days ago" is the case that
# matters here — it is what turns a verified balance back into a presumed one.
#
#   PR05 PR06 PR07  counted in the last fortnight  → verified, no mark
#   PR08 PR09       counted before the last mission → "presumido desde ..."
#   PR01..PR04 PR10 out with the mission            → "presumido · nunca contada"
#
# The 30-day line is `StockLive.Index`'s own; these dates straddle it on purpose.
verified_days_ago = %{"PR05" => 6, "PR06" => 9, "PR07" => 13, "PR08" => 48, "PR09" => 74}

for {code, days} <- verified_days_ago do
  box = Repo.one!(from b in Box, where: b.code == ^code)

  box
  |> Ecto.Changeset.change(%{
    last_verified_at: DateTime.add(DateTime.utc_now(:second), -days, :day)
  })
  |> Repo.update!()
end

counted_boxes = Repo.aggregate(from(b in Box, where: not is_nil(b.last_verified_at)), :count)

stale_cutoff = DateTime.add(DateTime.utc_now(:second), -30, :day)

fresh_boxes =
  Repo.aggregate(from(b in Box, where: b.last_verified_at > ^stale_cutoff), :count)

unboxed = Repo.aggregate(from(s in StockSnapshot, where: s.quantity != 0 and is_nil(s.box_id)), :count)

IO.puts("""

=== the cases the screens need ===
  expired positions:      #{expired}
  expiring within 90d:    #{expiring}
  positions in no box:    #{unboxed}
  boxes counted:          #{counted_boxes} of #{Repo.aggregate(Box, :count)}
    still fresh (<30d):   #{fresh_boxes}
    counted but stale:    #{counted_boxes - fresh_boxes}
    never counted:        #{Repo.aggregate(Box, :count) - counted_boxes}
  below minimum:          #{length(EstoqueOS.Reports.below_minimum(limit: 50))}
  kits:                   #{Repo.aggregate(Kits.Kit, :count)}

=== totals ===
  lots:        #{Repo.aggregate(Lot, :count)}
  boxes:       #{Repo.aggregate(Box, :count)}
  balance:     #{Inventory.balance()}
  #{warehouse.name}: #{Inventory.balance(location_id: warehouse.id)}
  #{current_site.name}: #{Inventory.balance(location_id: current_site.id)}
  #{transit.name}: #{Inventory.balance(location_id: transit.id)}
""")
