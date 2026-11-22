defmodule EstoqueOS.DemoData do
  @moduledoc """
  The scenario the screens are demonstrated and developed against.

  `EstoqueOS.Seeds` loads what a fresh install has (locations, supply table,
  kits) and no stock. This builds a warehouse that has been running a while on
  top of it, because the screens that compare need history to compare.

  Lives in `lib/` because the demo deployment has no checkout and no `mix`;
  `EstoqueOS.Release.demo/0` and `mix dev.seeds` call the same function.

  Builds: one admin account, one warehouse with ten boxes (one the office box),
  medical supply with spread expiries, office equipment, marketing stock, two
  invoices (one posted, one pending), one kit resolved and assembled and four
  left unresolved, two closed missions, one open mission, a few short products
  and boxes counted at different times.

  Refuses to run twice: it would double every balance. Sized to stay well under
  a ten-thousand-row free-tier database.
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

  # Printed at the end; twelve characters is the changeset minimum.
  @demo_password "demonstracao2026"

  # Deliberately one account: creating the rest is the first admin flow
  # (temporary password, forced change, roles) and is worth walking, not seeding.
  @accounts [{"admin@exemplo.org", "admin"}]

  @marketing_items [
    {"Camiseta Operação Sorriso P", "UN", 40},
    {"Camiseta Operação Sorriso M", "UN", 60},
    {"Camiseta Operação Sorriso G", "UN", 45},
    {"Boné bordado", "UN", 30},
    {"Caneca Operação Sorriso", "UN", 24},
    {"Sacola de algodão", "UN", 80}
  ]

  @office_items [
    {"Impressora multifuncional", "UN", 2},
    {"Scanner portátil", "UN", 2},
    {"Papel A4 (resma)", "RESMA", 20},
    {"Caneta esferográfica azul", "UN", 50},
    {"Lápis preto", "UN", 50}
  ]

  # `{city, days_before_today, length, surgeries}`; consumption scales with surgeries.
  @closed_missions [
    {"Tefé", -240, 7, 31},
    {"Carauari", -95, 3, 14}
  ]
  @open_mission {"Manacapuru", -6, 7, 28}

  # Supply boxes that go out with the open mission; the opening stock keeps the
  # kit's components out of them.
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

    # The admin is the only account, so every seeded movement is theirs.
    logistics = admin

    warehouse = warehouse()
    boxes = boxes(warehouse)
    office_box = List.last(boxes)
    supply_boxes = Enum.take(boxes, length(boxes) - 1)

    office = office_stock()
    marketing = marketing_stock()
    kit = resolve_one_kit()
    supply = supply_stock(today, kit)

    open_stock(
      logistics,
      warehouse,
      supply_boxes,
      office_box,
      supply,
      office ++ marketing,
      today
    )

    invoices = invoices(admin, warehouse)

    # Order matters: assemble while components are clean, then expire one, so
    # the demo shows a kit in stock and the refusal to build another.
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
       marketing_products: length(marketing),
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

    # Cleared: a demo account must not demand a password change before showing anything.
    user
    |> Ecto.Changeset.change(must_reset_password: false)
    |> Repo.update!()
  end

  # The other locations `Seeds` ships are deactivated, not deleted (transactions
  # name them); `default_location/0` then falls through to this warehouse.
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

  # The last of the ten is the office box: it travels with every mission and
  # nothing in it is ever issued.
  defp boxes(warehouse) do
    for n <- 1..10 do
      code = "PR#{String.pad_leading("#{n}", 2, "0")}"
      {:ok, box} = Locations.create_box(%{code: code, location_id: warehouse.id})
      box
    end
  end

  # `segment` is all that makes this a second stock.
  defp marketing_stock do
    for {name, unit, quantity} <- @marketing_items do
      {:ok, product} =
        Catalog.create_product(%{
          name: name,
          stock_unit: unit,
          segment: "marketing",
          sector: "MARKETING",
          expiry_expected: false,
          lot_expected: false,
          min_stock_override: Decimal.new(div(quantity, 4))
        })

      {:ok, lot} =
        %Lot{}
        |> Lot.changeset(%{product_id: product.id, lot_number: nil})
        |> Repo.insert()

      %{product: product, lot: lot, quantity: quantity}
    end
  end

  # Paper does not expire and a scanner has no lot, so neither blank is an alarm.
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

  # Four of five kits arrive with lines naming items the catalog lacks. One is
  # resolved fully here; the other four stay unresolved so that state is visible.
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

  # Every product the resolved kit needs, plus enough of the catalog to page
  # through. Expiry is spread: a few past, a few in the alert window, most fine.
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

    # Extras first: `expiry_for/2` front-loads expired dates and FEFO picks the
    # oldest, so kit components first would assemble an already-expired kit lot.
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
      index < 3 -> Date.add(today, -30 * (index + 1))
      index < 8 -> Date.add(today, 20 * (index - 2))
      true -> Date.add(today, 200 + index * 30)
    end
  end

  # Everything lands in a box: loose stock cannot travel.
  defp open_stock(user, warehouse, supply_boxes, office_box, supply, office, today) do
    # A lot lives in one box, which decides whether it travels. The kit's
    # components stay out of the travelling boxes, or every kit reads "0 possíveis".
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

  # One posted invoice (unit cost from a document) and one imported and waiting.
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

    # The correction letter is stored and attached, with no field-level reprocessing.
    {:ok, _event} =
      Samples.correction_letter() |> Samples.read!() |> Invoices.attach_event()

    # Lots arrive in the `rastro` group; what is missing is the catalog product
    # and the unit conversion, which the receiving screen asks a person.
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

  # Reuse a product whose name matches the description, else create one.
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

  # "1 PT = 50 UN": a property of the packaging, so per commercial unit.
  defp conversion_factor_for(item) do
    case item.commercial_unit do
      "PT" -> 50
      "CX" -> 100
      "PC" -> 1
      "UN" -> 1
      _other -> 1
    end
  end

  # `allow_partial` builds as many whole kits as the components allow.
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

  # A component lot that expired last week: the assembly screen refuses another
  # kit until it is written off. The kit already assembled is untouched.
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

  # Written straight to the ledger with historical dates, not through the
  # outbound flows, which stamp the current time. The office box returns whole.
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

    # Handed to the hospital: still exists, so a donation, not a write-off.
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

  # Goes through the real flows and is left open, so the live screens have
  # something honest to show.
  defp open_mission(user, warehouse, supply_boxes, office_box, today) do
    {city, offset, days, surgeries} = @open_mission
    site = mission_site("Missão #{city}")
    left_on = Date.add(today, offset)

    {:ok, mission} =
      Missions.create_mission(%{
        name: "#{city} #{left_on.year}/2",
        location_id: site.id,
        starts_on: left_on,
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

  # Three products are written below the mission minimum; a shortage list of
  # everything would not be read.
  defp write_some_products_short(user, warehouse, _supply) do
    # Chosen from what is on the shelf after the missions ran, not before.
    StockSnapshot
    |> where([s], s.location_id == ^warehouse.id and s.quantity > 100 and not is_nil(s.box_id))
    |> order_by([s], asc: s.lot_id)
    |> limit(3)
    |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
    |> Repo.all()
    |> Enum.map(fn row ->
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

  # Without some counted boxes every row reads "presumido · nunca contada" and
  # the mark tells nothing. Written straight to the column because
  # `mark_box_verified/1` stamps now; these dates straddle `StockLive.Index`'s
  # 30-day line on purpose.
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
      marketing stock:  #{summary.marketing_products} products, sold rather than consumed
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
