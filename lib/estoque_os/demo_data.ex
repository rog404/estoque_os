defmodule EstoqueOS.DemoData do
  @moduledoc """
  The scenario the screens are demonstrated and developed against.

  `EstoqueOS.Seeds` loads the truth a fresh install has: the locations, the 322
  lines of the standard supply table, and the five kits. It creates no stock,
  which is correct — a new install has none. This builds a warehouse that has
  been running for a while on top of it, because the screens that matter most
  are the ones that compare. A stock list with one lot in it teaches nothing,
  and "below minimum" means nothing without something having been used up.

  It lives in `lib/` rather than in `priv/repo/`, unlike the usual seed script,
  because the demo deployment has to be able to run it: there is no checkout on
  the server and no `mix`. `EstoqueOS.Release.demo/0` calls it, and
  `mix dev.seeds` calls the same function so the two cannot drift.

  What it builds:

    * four accounts, one per role, so the demo can be walked through as each
    * one warehouse, "Principal", with ten boxes — one of them the office box
    * medical supply in lots that expire on a spread, a few already expired
    * office equipment and stationery, which travel from mission to mission and
      are never issued
    * two invoices: one conferred, resolved and posted, so its goods are in
      stock at a real unit cost; one imported and left waiting, which is the
      state most invoices are actually in
    * one kit fully resolved against the catalog and assembled into stock, and
      four left as the spreadsheets wrote them — naming items in free text that
      the catalog does not have — because that is the state the kit screens
      exist to work through
    * two closed missions with their load-out, consumption, donation and return
    * one mission under way, so the live screens have something to show
    * a handful of products left short, and boxes counted at different times

  Refuses to run twice: running it again would silently double every balance.

  Sized for a free-tier database with a ten thousand row ceiling. It settles
  around fifteen hundred.
  """

  import Ecto.Query

  alias EstoqueOS.Accounts
  alias EstoqueOS.Catalog
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Box
  alias EstoqueOS.Inventory.Location
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Inventory.Lot
  alias EstoqueOS.Inventory.StockSnapshot
  alias EstoqueOS.Invoices
  alias EstoqueOS.Kits
  alias EstoqueOS.Kits.Kit
  alias EstoqueOS.Missions
  alias EstoqueOS.Outbound
  alias EstoqueOS.Repo
  alias EstoqueOS.Samples

  @guard_box "PR01"

  # One password for every demo account, printed at the end. Twelve characters
  # is the minimum the changeset accepts.
  @demo_password "demonstracao2026"

  # One account, and deliberately one. Creating the rest is the first thing an
  # administrator does on a fresh install, and it is a flow worth walking rather
  # than seeding around — the temporary password, the forced change on first
  # login, the role that decides whether prices are visible at all. A seed that
  # hands over four ready accounts quietly skips the screen that matters most on
  # day one.
  @accounts [{"admin@exemplo.org", "admin"}]

  @office_items [
    {"Impressora multifuncional", "UN", 2},
    {"Scanner portátil", "UN", 2},
    {"Papel A4 (resma)", "RESMA", 20},
    {"Caneta esferográfica azul", "UN", 50},
    {"Lápis preto", "UN", 50}
  ]

  # Two closed and one under way. `{city, days_before_today, length, surgeries}`.
  # A mission is usually a week; the short one is the weekend format the
  # operation also runs, and consumption is scaled from the surgery count
  # because that is how the operation compares one trip to another.
  @closed_missions [
    {"Tefé", -240, 7, 31},
    {"Carauari", -95, 3, 14}
  ]
  @open_mission {"Manacapuru", -6, 7, 28}

  # How many of the supply boxes go out with the open mission. Named because
  # two places depend on the same number: the load-out takes these, and the
  # opening stock keeps the resolved kit's components out of them.
  @travelling_box_count 4

  @doc """
  Builds the scenario. Returns a summary, or `{:error, :already_loaded}`.
  """
  def run do
    if Repo.exists?(from b in Box, where: b.code == @guard_box) do
      {:error, :already_loaded}
    else
      build()
    end
  end

  @doc """
  Builds the scenario and prints what it made. This is what `mix dev.seeds` and
  `EstoqueOS.Release.demo/0` call.
  """
  def run!(io \\ :stdio) do
    case run() do
      {:error, :already_loaded} ->
        IO.puts(io, """

        The scenario is already loaded (box #{@guard_box} exists).

        Running again would double every balance, so this stops here. To rebuild
        it locally:

            mix ecto.reset && mix dev.seeds
        """)

        {:error, :already_loaded}

      {:ok, summary} ->
        report(io, summary)
        {:ok, summary}
    end
  end

  defp build do
    today = Date.utc_today()

    users = accounts()
    admin = Map.fetch!(users, "admin")

    # Every movement the scenario writes is the administrator's, because the
    # administrator is the only account there is. Real movements carry the
    # person who made them; a seed carries whoever ran the seed.
    logistics = admin

    warehouse = warehouse()
    boxes = boxes(warehouse)
    office_box = List.last(boxes)
    supply_boxes = Enum.take(boxes, length(boxes) - 1)

    office = office_stock()
    kit = resolve_one_kit()
    supply = supply_stock(today, kit)

    open_stock(logistics, warehouse, supply_boxes, office_box, supply, office, today)

    invoices = invoices(admin, warehouse)

    # Order matters. The kit is assembled while its components are clean, and
    # one of them is expired straight after — so the demo holds both states at
    # once: a kit in stock, and the refusal on screen the next time somebody
    # tries to build another.
    assembled = assemble_kit(kit, logistics, warehouse, List.first(supply_boxes))
    expired_component = expire_one_kit_component(kit, logistics, warehouse, supply_boxes, today)

    closed =
      Enum.map(@closed_missions, fn plan ->
        close_mission(plan, logistics, warehouse, supply_boxes, office_box, supply, today)
      end)

    open = open_mission(logistics, warehouse, supply_boxes, office_box, today)
    short = write_some_products_short(logistics, warehouse, supply)
    counted = stamp_counts()

    {:ok,
     %{
       accounts: users |> Map.values() |> Enum.map(& &1.email) |> Enum.sort(),
       password: @demo_password,
       warehouse: warehouse,
       boxes: length(boxes),
       office_box: office_box.code,
       supply_products: length(supply),
       office_products: length(office),
       invoices: invoices,
       kit: kit,
       assembled: assembled,
       closed_missions: closed,
       open_mission: open,
       short_products: short,
       counted_boxes: counted,
       expired_component: expired_component
     }}
  end

  ## Who

  defp accounts do
    Map.new(@accounts, fn {email, role} ->
      user =
        case Accounts.get_user_by_email(email) do
          nil -> provision(email, role)
          found -> found
        end

      {role, user}
    end)
  end

  defp provision(email, role) do
    {:ok, {user, _password}} =
      Accounts.create_user_with_temporary_password(email, role, password: @demo_password)

    # Cleared deliberately. Every real account starts with the forced password
    # change, which is right; a demo account that demands a new password before
    # it will show anything is not a demo account.
    user
    |> Ecto.Changeset.change(must_reset_password: false)
    |> Repo.update!()
  end

  ## Where

  # One warehouse, because that is what the scenario is about. The other
  # locations `Seeds` ships are deactivated rather than deleted: transactions
  # name the location they moved stock from, and `default_location/0` falls
  # through to the first active warehouse, which is this one.
  defp warehouse do
    {:ok, warehouse} =
      case Repo.get_by(Location, name: "Principal") do
        nil -> Locations.create_location(%{name: "Principal", kind: "warehouse"})
        found -> {:ok, found}
      end

    Location
    |> where([l], l.kind == "warehouse" and l.id != ^warehouse.id)
    |> Repo.update_all(set: [active: false, updated_at: DateTime.utc_now(:second)])

    warehouse
  end

  defp mission_site(name) do
    case Repo.get_by(Location, name: name) do
      nil ->
        {:ok, site} = Locations.create_location(%{name: name, kind: "mission_site"})
        site

      found ->
        found
    end
  end

  # Ten, and the last one is the office box: the printer, the scanner and the
  # stationery live in it and travel with every mission. Nothing in it is ever
  # issued — it goes out and comes back, which is exactly why it must be a box.
  defp boxes(warehouse) do
    for n <- 1..10 do
      code = "PR#{String.pad_leading("#{n}", 2, "0")}"
      {:ok, box} = Locations.create_box(%{code: code, location_id: warehouse.id})
      box
    end
  end

  ## What

  # Office equipment and stationery are ordinary products, not a new concept.
  # What separates them is `sector`, `expiry_expected` and `lot_expected` —
  # paper does not expire and a scanner has no lot number, so neither blank is
  # an alarm.
  defp office_stock do
    for {name, unit, quantity} <- @office_items do
      {:ok, product} =
        Catalog.create_product(%{
          name: name,
          stock_unit: unit,
          sector: "ESCRITÓRIO",
          expiry_expected: false,
          lot_expected: false,
          min_stock_override: Decimal.new(quantity)
        })

      {:ok, lot} =
        %Lot{}
        |> Lot.changeset(%{product_id: product.id, lot_number: nil})
        |> Repo.insert()

      %{product: product, lot: lot, quantity: quantity}
    end
  end

  # The kit sheets name items in free text — "Compressa de gaze 7,5x7,5" — and
  # most of those names are not in the standard supply table, so four of the
  # five kits arrive with lines pointing at nothing. That is the real state of
  # the data and the kit screen exists to work through it.
  #
  # One kit is walked all the way through here: every unresolved line gets a
  # catalog product created for it and is pointed at it, which is what a
  # coordinator would do. The other four are left as they came, so the "linhas
  # não resolvidas" state is on screen too.
  defp resolve_one_kit do
    kit = smallest_resolvable_kit()

    for item <- kit.items, is_nil(item.product_id) do
      {:ok, product} =
        Catalog.create_product(%{
          name: item.description,
          stock_unit: "UN",
          sector: "ENFERMAGEM",
          expiry_expected: true
        })

      {:ok, _item} = Kits.update_kit_item(item, %{product_id: product.id})
    end

    Kits.get_kit!(kit.id)
  end

  # Fewest unresolved lines: the fewest products invented to get one kit whole.
  defp smallest_resolvable_kit do
    Kit
    |> Repo.all()
    |> Enum.map(&Kits.get_kit!(&1.id))
    |> Enum.min_by(fn kit -> Enum.count(kit.items, &is_nil(&1.product_id)) end)
  end

  # Every product the resolved kit needs, so it can actually be assembled, plus
  # enough of the rest of the catalog that the stock list is worth paging
  # through. Expiry is spread on purpose: a few already past, a few inside the
  # alert window, most comfortable.
  defp supply_stock(today, kit) do
    needed = kit.items |> Enum.map(& &1.product_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    extras =
      Product
      |> where([p], p.active and not is_nil(p.sector) and p.sector != "ESCRITÓRIO")
      |> where([p], p.id not in ^needed)
      |> order_by([p], asc: p.id)
      |> limit(60)
      |> select([p], p.id)
      |> Repo.all()

    # Extras first, deliberately. `expiry_for/2` puts the expired and
    # nearly-expired dates at the front of the list, and FEFO picks the oldest
    # lot first — so with the kit's own components at the front, assembling the
    # kit produced a kit lot that was already expired the moment it existed.
    # True to the rules and useless to look at.
    (extras ++ needed)
    |> Enum.with_index()
    |> Enum.map(fn {product_id, index} ->
      {:ok, lot} =
        %Lot{}
        |> Lot.changeset(%{
          product_id: product_id,
          lot_number: "L#{2000 + index}",
          expires_on: expiry_for(today, index)
        })
        |> Repo.insert()

      %{
        product: Repo.get!(Product, product_id),
        lot: lot,
        index: index,
        kit_component?: product_id in needed
      }
    end)
  end

  defp expiry_for(today, index) do
    cond do
      # A few genuinely expired, which the dashboard must surface.
      index < 3 -> Date.add(today, -30 * (index + 1))
      # A few inside the alert window.
      index < 8 -> Date.add(today, 20 * (index - 2))
      # The rest comfortable.
      true -> Date.add(today, 200 + index * 30)
    end
  end

  # Everything lands in a box. Loose stock is a real state — goods that arrived
  # and nobody has conferred yet — but it cannot travel, so a scenario that
  # opened with it would have nothing to send.
  defp open_stock(user, warehouse, supply_boxes, office_box, supply, office, today) do
    # A lot lives in exactly one box, so which box decides whether it travels.
    # The open mission takes the first four; the kit's components are kept out
    # of those, because a component that left with the mission is a component
    # the warehouse has none of — and the dashboard then reports every kit as
    # "0 possíveis", which is true and reads like the feature is broken.
    staying = Enum.drop(supply_boxes, @travelling_box_count)

    supply_entries =
      Enum.map(supply, fn %{lot: lot, index: index, kit_component?: kit_component?} ->
        pool = if kit_component?, do: staying, else: supply_boxes

        %{
          lot_id: lot.id,
          location_id: warehouse.id,
          box_id: Enum.at(pool, rem(index, length(pool))).id,
          quantity: 400 + rem(index * 37, 300),
          unit_cost: unit_cost_for(index)
        }
      end)

    office_entries =
      Enum.map(office, fn %{lot: lot, quantity: quantity} ->
        %{
          lot_id: lot.id,
          location_id: warehouse.id,
          box_id: office_box.id,
          quantity: quantity,
          unit_cost: Decimal.new("15.00")
        }
      end)

    {:ok, _} =
      post(%{
        type: "purchase_in",
        user_id: user.id,
        occurred_at: DateTime.new!(Date.add(today, -400), ~T[09:00:00]),
        notes: "Estoque inicial",
        entries: supply_entries ++ office_entries
      })

    :ok
  end

  defp unit_cost_for(index) do
    cents = (index * 7) |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    Decimal.new("#{rem(index, 30) + 2}.#{cents}")
  end

  ## The invoices
  #
  # Two, in the two states an invoice is actually found in. The first is
  # conferred, resolved and posted, so its goods are in stock at a unit cost
  # that came from a document rather than from this file. The second is
  # imported and waiting — which is where most invoices sit, and what the
  # "pendentes" count on the dashboard is counting.

  defp invoices(user, warehouse) do
    posted = import_and_post(user, warehouse)
    pending = import_only(user)

    %{posted: posted, pending: pending}
  end

  defp import_and_post(user, warehouse) do
    {:ok, invoice} =
      Samples.invoice_with_rastro()
      |> Samples.read!()
      |> Invoices.import_document(user_id: user.id)

    # The correction letter that came after it. Stored and attached; no
    # field-level reprocessing, which is the documented MVP behaviour.
    {:ok, _event} =
      Samples.correction_letter() |> Samples.read!() |> Invoices.attach_event()

    # This invoice ships its lot numbers in the structured `rastro` group, so
    # every line arrives with a lot already. What is missing is the catalog
    # product and how many stock units the commercial unit holds — the two
    # questions the receiving screen asks a person.
    for item <- Invoices.get_invoice!(invoice.id).items do
      {:ok, product} = catalog_product_for(item)

      {:ok, _resolved} =
        Invoices.resolve_item(item, %{
          product_id: product.id,
          conversion_factor: conversion_factor_for(item)
        })
    end

    {:ok, %{invoice: posted}} =
      Invoices.get_invoice!(invoice.id)
      |> Invoices.post_invoice(%{location_id: warehouse.id, user_id: user.id})

    posted
  end

  defp import_only(user) do
    {:ok, invoice} =
      Samples.invoice_with_inf_ad_prod()
      |> Samples.read!()
      |> Invoices.import_document(user_id: user.id)

    invoice
  end

  # The invoice describes the item the supplier's way; the catalog may or may
  # not already know it. Reuse an existing product when the description matches
  # one, create it otherwise — the same two outcomes the import screen offers.
  defp catalog_product_for(item) do
    name = item.description |> String.trim() |> String.slice(0, 200)

    case Repo.one(
           from p in Product, where: fragment("lower(?)", p.name) == ^String.downcase(name)
         ) do
      nil ->
        Catalog.create_product(%{
          name: name,
          stock_unit: "UN",
          ncm: item.ncm,
          sector: "SUPRIMENTOS",
          expiry_expected: true
        })

      found ->
        {:ok, found}
    end
  end

  # "1 PT = 50 UN". Invented per commercial unit rather than per line, which is
  # how the question is actually asked: it is a property of the packaging.
  defp conversion_factor_for(item) do
    case item.commercial_unit do
      "PT" -> 50
      "CX" -> 100
      "PC" -> 1
      "UN" -> 1
      _other -> 1
    end
  end

  ## The kits

  # Assembled into a box, which converts component lots into a lot of the kit's
  # own product. `allow_partial` because the components on hand are what they
  # are: it builds as many whole kits as it can rather than refusing.
  defp assemble_kit(kit, user, warehouse, box) do
    case Kits.assemble(kit, 10, %{
           location_id: warehouse.id,
           box_id: box.id,
           user_id: user.id,
           allow_partial: true
         }) do
      {:ok, result} -> {:ok, result}
      other -> other
    end
  end

  # A lot of one component that expired last week, received before it did. The
  # assembly screen refuses to build another kit until it is written off, which
  # is the rule worth being able to see rather than read about — and the kit
  # already in the box is untouched, because it was sealed before this arrived.
  defp expire_one_kit_component(kit, user, warehouse, supply_boxes, today) do
    component = kit.items |> Enum.reject(&is_nil(&1.product_id)) |> List.first()

    {:ok, lot} =
      %Lot{}
      |> Lot.changeset(%{
        product_id: component.product_id,
        lot_number: "L1999",
        expires_on: Date.add(today, -8)
      })
      |> Repo.insert()

    {:ok, _} =
      post(%{
        type: "purchase_in",
        user_id: user.id,
        occurred_at: DateTime.new!(Date.add(today, -120), ~T[10:00:00]),
        notes: "Lote que venceu na prateleira",
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: List.last(supply_boxes).id,
            quantity: 24,
            unit_cost: Decimal.new("3.40")
          }
        ]
      })

    component.description
  end

  ## The missions

  # A closed mission, written straight to the ledger with its real dates: goods
  # leave in boxes, some are used, some are handed to the hospital, the rest
  # comes back. The office box always returns whole — that is the point of it.
  #
  # Constructed rather than run through the outbound flows because those stamp
  # the clock, which is right for an operator standing in the warehouse and
  # wrong for a seed writing history.
  defp close_mission(
         {city, offset, days, surgeries},
         user,
         warehouse,
         supply_boxes,
         office_box,
         supply,
         today
       ) do
    site = mission_site("Missão #{city}")
    left_on = Date.add(today, offset)
    back_on = Date.add(left_on, days)

    {:ok, mission} =
      Missions.create_mission(%{
        name: "#{city} #{left_on.year}/#{if left_on.month <= 6, do: 1, else: 2}",
        location_id: site.id,
        starts_on: left_on,
        ends_on: back_on,
        tables: if(days <= 3, do: 2, else: 4),
        notes: "#{surgeries} cirurgias"
      })

    sent =
      supply
      |> Enum.take(12)
      |> Enum.with_index()
      |> Enum.map(fn {%{lot: lot}, index} ->
        %{
          lot: lot,
          box: Enum.at(supply_boxes, rem(index, length(supply_boxes))),
          quantity: Decimal.new(surgeries * (2 + rem(index, 4)))
        }
      end)

    office_positions = positions_in_box(office_box, warehouse)

    {:ok, _} =
      post(%{
        type: "load_out",
        user_id: user.id,
        mission_id: mission.id,
        source_location_id: warehouse.id,
        destination_location_id: site.id,
        occurred_at: DateTime.new!(left_on, ~T[07:00:00]),
        notes: "Derrubada para #{mission.name}",
        entries:
          Enum.flat_map(sent, fn %{lot: lot, box: box, quantity: quantity} ->
            move(lot.id, box.id, warehouse.id, site.id, quantity)
          end) ++
            Enum.flat_map(office_positions, fn row ->
              move(row.lot_id, office_box.id, warehouse.id, site.id, row.quantity)
            end)
      })

    {:ok, _} =
      post(%{
        type: "manual_out",
        user_id: user.id,
        mission_id: mission.id,
        source_location_id: site.id,
        destination: "operating_room",
        occurred_at: DateTime.new!(Date.add(left_on, 2), ~T[14:00:00]),
        notes: "Consumo em #{surgeries} cirurgias",
        entries:
          Enum.map(sent, fn %{lot: lot, box: box, quantity: quantity} ->
            used = quantity |> Decimal.mult(Decimal.new("0.55")) |> Decimal.round(0)

            %{
              lot_id: lot.id,
              location_id: site.id,
              box_id: box.id,
              quantity: Decimal.negate(used)
            }
          end)
      })

    # Handed to the hospital at the end. Not consumed — it still exists, which
    # is why it is a donation and not a write-off.
    {:ok, _} =
      post(%{
        type: "manual_out",
        user_id: user.id,
        mission_id: mission.id,
        source_location_id: site.id,
        destination: "donation",
        recipient_name: "Hospital de #{city}",
        occurred_at: DateTime.new!(back_on, ~T[16:00:00]),
        notes: "Termo de doação ao fim da missão",
        entries:
          sent
          |> Enum.take(4)
          |> Enum.map(fn %{lot: lot, box: box, quantity: quantity} ->
            given = quantity |> Decimal.mult(Decimal.new("0.15")) |> Decimal.round(0)

            %{
              lot_id: lot.id,
              location_id: site.id,
              box_id: box.id,
              quantity: Decimal.negate(given)
            }
          end)
      })

    remaining =
      StockSnapshot
      |> where([s], s.location_id == ^site.id and s.quantity > 0)
      |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
      |> Repo.all()

    if remaining != [] do
      {:ok, _} =
        post(%{
          type: "return_in",
          user_id: user.id,
          mission_id: mission.id,
          source_location_id: site.id,
          destination_location_id: warehouse.id,
          occurred_at: DateTime.new!(Date.add(back_on, 1), ~T[11:00:00]),
          notes: "Retorno de #{mission.name}",
          entries:
            Enum.flat_map(remaining, fn row ->
              move(row.lot_id, row.box_id, site.id, warehouse.id, row.quantity)
            end)
        })
    end

    mission
  end

  # This one goes through the real flows, so the live screens — load-out, the
  # mission panel's warning line — have something honest to show. Deliberately
  # left open: the goods are at the site, nothing has come back.
  defp open_mission(user, warehouse, supply_boxes, office_box, today) do
    {city, offset, days, surgeries} = @open_mission
    site = mission_site("Missão #{city}")
    left_on = Date.add(today, offset)

    {:ok, mission} =
      Missions.create_mission(%{
        name: "#{city} #{left_on.year}/2",
        location_id: site.id,
        starts_on: left_on,
        # Planned, not yet happened: the team is still there.
        ends_on: Date.add(left_on, days),
        tables: 4,
        notes: "#{surgeries} cirurgias"
      })

    travelling = Enum.take(supply_boxes, @travelling_box_count) ++ [office_box]

    {:ok, _} =
      Outbound.load_out(%{
        source_location_id: warehouse.id,
        destination_location_id: site.id,
        box_ids: Enum.map(travelling, & &1.id),
        user_id: user.id,
        notes: "Derrubada para #{mission.name}"
      })

    # Some of it already used on site, so the panel is not all zeroes.
    used =
      StockSnapshot
      |> where([s], s.location_id == ^site.id and s.quantity > 20)
      |> limit(6)
      |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
      |> Repo.all()

    if used != [] do
      {:ok, _} =
        post(%{
          type: "manual_out",
          user_id: user.id,
          mission_id: mission.id,
          source_location_id: site.id,
          destination: "operating_room",
          notes: "Consumo em andamento",
          entries:
            Enum.map(used, fn row ->
              %{
                lot_id: row.lot_id,
                location_id: site.id,
                box_id: row.box_id,
                quantity:
                  row.quantity
                  |> Decimal.mult(Decimal.new("0.3"))
                  |> Decimal.round(0)
                  |> Decimal.negate()
              }
            end)
        })
    end

    mission
  end

  ## Something to be short of

  # A shortage list that lists everything is a list nobody reads. Three
  # products are written down below the minimum a mission is expected to carry;
  # the rest stay comfortable.
  defp write_some_products_short(user, warehouse, _supply) do
    # Chosen from what is actually on the shelf now rather than picked before
    # the missions ran and spent by them — the first version of this drew down
    # three lots that two closed missions had already emptied, and wrote one
    # product short instead of three.
    StockSnapshot
    |> where([s], s.location_id == ^warehouse.id and s.quantity > 100 and not is_nil(s.box_id))
    |> order_by([s], asc: s.lot_id)
    |> limit(3)
    |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
    |> Repo.all()
    |> Enum.map(fn row ->
      # Down to a tenth, which is under any plausible minimum for a mission.
      keep = row.quantity |> Decimal.mult(Decimal.new("0.1")) |> Decimal.round(0)

      post(%{
        type: "adjustment",
        user_id: user.id,
        reason_code: "count_correction",
        notes: "Ajuste de contagem — cenário de falta",
        entries: [
          %{
            lot_id: row.lot_id,
            location_id: warehouse.id,
            box_id: row.box_id,
            quantity: Decimal.negate(Decimal.sub(row.quantity, keep))
          }
        ]
      })
    end)
    |> Enum.count(&match?({:ok, _}, &1))
  end

  ## Counts

  # Until a box has been counted, every position on the stock screen reads
  # "presumido · nunca contada" — and a mark that is on every row is a mark
  # that tells you nothing. The screen's claim is that it separates what was
  # counted from what is inherited, and it cannot demonstrate that claim
  # without both.
  #
  # Written straight to the column: `mark_box_verified/1` stamps *now*, and
  # "counted 48 days ago" is the case that matters — it is what turns a
  # verified balance back into a presumed one. The 30-day line is
  # `StockLive.Index`'s own; these dates straddle it on purpose.
  #
  #   PR05 PR06 PR07  counted in the last fortnight   → verified, no mark
  #   PR08 PR09       counted before the last mission → "presumido desde ..."
  #   PR01..PR04 PR10 out with the mission            → never counted
  defp stamp_counts do
    now = DateTime.utc_now(:second)

    for {code, days_ago} <- %{"PR05" => 6, "PR06" => 9, "PR07" => 13, "PR08" => 48, "PR09" => 74} do
      Box
      |> Repo.get_by!(code: code)
      |> Ecto.Changeset.change(last_verified_at: DateTime.add(now, -days_ago, :day))
      |> Repo.update!()
    end
    |> length()
  end

  ## Helpers

  defp post(attrs), do: Inventory.post_transaction(attrs)

  # A move is two signed entries: out of where it was, into where it went.
  defp move(lot_id, box_id, from_id, to_id, quantity) do
    [
      %{
        lot_id: lot_id,
        location_id: from_id,
        box_id: box_id,
        quantity: Decimal.negate(quantity)
      },
      %{lot_id: lot_id, location_id: to_id, box_id: box_id, quantity: quantity}
    ]
  end

  defp positions_in_box(box, location) do
    StockSnapshot
    |> where([s], s.box_id == ^box.id and s.location_id == ^location.id and s.quantity > 0)
    |> select([s], %{lot_id: s.lot_id, quantity: s.quantity})
    |> Repo.all()
  end

  defp report(io, summary) do
    rows = Repo.aggregate(from(e in EstoqueOS.Inventory.TransactionEntry), :count)

    IO.puts(io, """

    === what was created ===
      warehouse:        #{summary.warehouse.name} (others deactivated)
      boxes:            #{summary.boxes} (#{summary.office_box} is the office box)
      supply products:  #{summary.supply_products}
      office products:  #{summary.office_products}
      invoices:         NF #{summary.invoices.posted.number} lançada, \
    NF #{summary.invoices.pending.number} pendente de entrada
      kit assembled:    #{kit_line(summary)}
      missions closed:  #{Enum.map_join(summary.closed_missions, ", ", & &1.name)}
      mission open:     #{summary.open_mission.name}
      expired on shelf: #{summary.expired_component} — blocks assembling another
      short products:   #{summary.short_products}
      counted boxes:    #{summary.counted_boxes} of #{summary.boxes}
      ledger entries:   #{rows}

    === how to log in ===
    #{Enum.map_join(summary.accounts, "\n", &"  #{&1}")}

      senha: #{summary.password}
    """)
  end

  defp kit_line(%{kit: kit, assembled: {:ok, result}}) do
    "#{kit.name} × #{result[:quantity] || result[:assembled] || "?"}"
  end

  defp kit_line(%{kit: kit, assembled: other}) do
    "#{kit.name} — SKIPPED (#{inspect(other)})"
  end
end
