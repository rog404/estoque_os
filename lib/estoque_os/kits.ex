defmodule EstoqueOS.Kits do
  @moduledoc """
  Kits: the bills of materials a mission works in.

  A kit is a product like any other, `kits.ex`'s own `products.kit_id` says
  so — it can be searched, issued, reported on, with no screen anywhere
  needing to know a kit is involved. What makes it a kit is `assemble/3`:
  the one operation that converts a recipe's worth of components into a new
  lot of that product. From the moment a lot exists, writing it off, moving
  it, counting it, is exactly what happens to a box of gauze.

  What that conversion would otherwise cost — knowing which component lots
  built a given kit lot, for a recall — is what `KitLotProvenance` buys back:
  a plain many-to-many between a kit's lot and the component lots consumed to
  build it.

  A kit line whose product nobody has resolved yet blocks assembly, loudly.
  The spreadsheets name components in free text, and silently skipping a line
  the system does not recognize is how a kit ships without its guedel
  cannula.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Lot
  alias EstoqueOS.Kits.{Kit, KitItem, KitLotProvenance}
  alias EstoqueOS.Repo

  ## Reading

  def get_kit!(id), do: Kit |> Repo.get!(id) |> load_kit()

  def list_kits do
    Kit
    |> where([k], k.active)
    |> order_by([k], asc: k.name)
    |> Repo.all()
    |> Enum.map(&load_kit/1)
  end

  # The order here is the order the components are read, packed and reported in,
  # so it cannot be left to the query plan: an unordered preload puts an updated
  # line wherever Postgres happened to produce it, and `assemble/3` names the
  # *first* component that is short. `KitItem` has no position of its own, so
  # insertion order is the spreadsheet's order — which is the order on paper.
  defp load_kit(kit) do
    Repo.preload(kit, [:product, items: {from(i in KitItem, order_by: [asc: i.id]), :product}],
      force: true
    )
  end

  @doc """
  Creates a kit and, in the same breath, the product that represents it in
  the catalog — a kit is never without one, the same way a `KitItem` is never
  without a description.
  """
  def create_kit(attrs) do
    Multi.new()
    |> Multi.insert(:kit, Kit.changeset(%Kit{}, attrs))
    |> Multi.insert(:product, fn %{kit: kit} ->
      Product.changeset(%Product{}, %{
        name: kit.name,
        stock_unit: "KIT",
        kit_id: kit.id,
        controlled: any_controlled?(kit.items)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{kit: kit}} -> {:ok, load_kit(kit)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp any_controlled?(%Ecto.Association.NotLoaded{}), do: false

  defp any_controlled?(items) do
    product_ids = items |> Enum.map(& &1.product_id) |> Enum.reject(&is_nil/1)

    product_ids != [] and
      Product |> where([p], p.id in ^product_ids and p.controlled) |> Repo.exists?()
  end

  @doc """
  Renames a kit and its product together — they are one name told twice, and
  a rename that only reached one of them would leave the write-off screen
  showing whatever the kit used to be called.
  """
  def update_kit(%Kit{} = kit, attrs) do
    Multi.new()
    |> Multi.update(:kit, Kit.changeset(kit, attrs))
    |> Multi.update(:product, fn %{kit: updated} ->
      Product.changeset(updated.product, %{name: updated.name})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{kit: updated}} -> {:ok, load_kit(updated)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def get_kit_item!(id), do: Repo.get!(KitItem, id)

  def update_kit_item(%KitItem{} = item, attrs) do
    item |> KitItem.changeset(attrs) |> Repo.update()
  end

  @doc "Adds one line to a kit's bill of materials."
  def add_kit_item(%Kit{} = kit, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    # A line somebody adds by hand must name a catalog product. A recipe made of
    # free text cannot say how many kits the stock covers, cannot be packed and
    # cannot be consumed — it is a shopping list with a kit's name on it.
    #
    # The rule lives here and not in the changeset because the importer needs
    # the other behaviour: seeding from `Kits.xlsx` records what the spreadsheet
    # said and flags the line unresolved, which is how those recipes reach the
    # screen where a person can link them.
    cond do
      blank?(attrs["product_id"]) ->
        {:error,
         %KitItem{}
         |> KitItem.changeset(attrs)
         |> Ecto.Changeset.add_error(:product_id, "precisa de um produto do catálogo")}

      # Now that a component *is* a product, the same product twice is two lines
      # claiming to be the same thing — and `availability/2` would count the
      # stock against each of them separately, so a kit needing 4 and 2 of one
      # item would report coverage for neither figure. Say so instead: the
      # quantity on the existing line is the thing to change.
      already_in?(kit, attrs["product_id"]) ->
        {:error, :already_a_component}

      true ->
        with {:ok, item} <-
               attrs
               |> Map.put("kit_id", kit.id)
               |> then(&KitItem.changeset(%KitItem{}, &1))
               |> Repo.insert() do
          sync_controlled(kit)
          {:ok, item}
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp already_in?(%Kit{} = kit, product_id) do
    product_id = to_id(product_id)

    kit
    |> Repo.preload(:items)
    |> Map.fetch!(:items)
    |> Enum.any?(&(&1.product_id == product_id))
  end

  @doc """
  Removes a line from a kit's bill of materials.

  Deleted outright, unlike anything in the ledger. A kit is a recipe, and a line
  nobody wants in it any more is an edit to a document — not a record of
  something that happened. What was actually built lives in the transactions
  and the lots, which this does not touch.
  """
  def remove_kit_item(%KitItem{} = item) do
    with {:ok, deleted} <- Repo.delete(item) do
      deleted.kit_id |> get_kit!() |> sync_controlled()
      {:ok, deleted}
    end
  end

  # A kit carries the badge of the most restrictive thing inside it — Portaria
  # 344 does not stop applying to a controlled drug because it is standing
  # next to gauze. Recomputed on every recipe edit rather than stored as a
  # choice, because a kit is controlled *because* of what is in it, not by
  # somebody's separate say-so.
  defp sync_controlled(%Kit{} = kit) do
    kit = load_kit(kit)
    controlled? = Enum.any?(kit.items, &(&1.product && &1.product.controlled))

    {:ok, _product} =
      kit.product |> Product.changeset(%{controlled: controlled?}) |> Repo.update()

    :ok
  end

  @doc """
  How many of this kit are in stock, anywhere.

  The kit's own product balance — the same number `Inventory.balance/1`
  would give for a box of gauze, because from the moment one is assembled
  that is exactly what a kit is.
  """
  def assembled_count(%Kit{} = kit), do: Inventory.balance(product_id: kit.product.id)

  @doc "Kit lines that still have no product in the catalog."
  def unresolved_items(%Kit{} = kit), do: Enum.filter(kit.items, &is_nil(&1.product_id))

  @doc """
  How many complete kits the stock at a location can cover, and what runs out
  first.

  The bottleneck is the useful half of the answer: "4 kits, and what stops the
  fifth is the guedel cannula" is a shopping list.
  """
  def availability(%Kit{} = kit, location_id) do
    resolved = Enum.filter(kit.items, & &1.product_id)

    # One query for the whole bill of materials. A balance per line meant 28
    # queries for Kit Paciente alone, and the kit listing asks this of every kit
    # on the screen.
    balances =
      resolved
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()
      |> Inventory.balances_by_product(location_id)

    lines =
      Enum.map(resolved, fn item ->
        available = Map.get(balances, item.product_id) || Decimal.new(0)
        possible = Decimal.div(available, item.quantity) |> Decimal.round(0, :down)

        %{item: item, available: available, needed_per_kit: item.quantity, possible: possible}
      end)

    possible =
      case lines do
        [] -> Decimal.new(0)
        lines -> lines |> Enum.map(& &1.possible) |> Enum.min_by(&Decimal.to_integer/1)
      end

    %{
      possible: possible,
      lines: lines,
      bottlenecks: Enum.filter(lines, &Decimal.equal?(&1.possible, possible)),
      unresolved: unresolved_items(kit)
    }
  end

  @doc """
  Where each resolved component of a kit is, box by box, at a location.

  The conference before assembling: `availability/2` says how much of a
  component there is; this says where to go stand to get it. A line whose
  product is unresolved has nothing to look up and is left out — it already
  blocks assembly on its own, loudly, elsewhere.
  """
  def box_breakdown(%Kit{} = kit, location_id) do
    kit.items
    |> Enum.filter(& &1.product_id)
    |> Map.new(fn item -> {item.id, Inventory.box_quantities(item.product_id, location_id)} end)
  end

  @doc """
  The conference for a requested `quantity`: how much each component needs,
  against what `availability/2` already found, and where to go stand for it
  per `box_breakdown/2`.

  Kept here rather than in the LiveView so a second screen that needs the same
  "how much does building N kits need" arithmetic finds it instead of
  reimplementing it.
  """
  def review_lines(%{lines: lines}, quantity, breakdown) do
    Enum.map(lines, fn line ->
      needed = Decimal.mult(line.item.quantity, quantity)

      %{
        item: line.item,
        needed: needed,
        available: line.available,
        short?: Decimal.compare(line.available, needed) == :lt,
        boxes: Map.get(breakdown, line.item.id, [])
      }
    end)
  end

  ## Assembling

  @doc """
  Converts `quantity` kits' worth of components into that quantity of the
  kit's own product, in one new lot, in `box_id`.

  Assembling is manufacturing, not packing: the components leave stock for
  good, drawn oldest expiry first, and what appears in the box instead is a
  lot of the kit. From here the kit is a product like any other — the same
  screen that writes off a bandage writes off a kit.

  A kit is never partially built: `quantity` is capped at the largest whole
  number the components on hand can cover. Asking for more than that is
  refused unless `allow_partial`, which builds as many complete kits as it
  can and says what stopped the rest.
  """
  def assemble(%Kit{} = kit, quantity, %{location_id: location_id, box_id: box_id} = opts) do
    quantity = to_decimal(quantity)

    cond do
      is_nil(quantity) or Decimal.compare(quantity, 0) != :gt ->
        {:error, :invalid_quantity}

      unresolved_items(kit) != [] ->
        {:error, {:unresolved_items, unresolved_items(kit)}}

      true ->
        do_assemble(kit, quantity, location_id, box_id, opts)
    end
  end

  defp do_assemble(kit, quantity, location_id, box_id, opts) do
    availability = availability(kit, location_id)
    possible = availability.possible

    if Decimal.compare(possible, quantity) == :lt and !opts[:allow_partial] do
      {:error, {:insufficient_stock, missing_for(availability, quantity)}}
    else
      build = Decimal.min(quantity, possible)

      if Decimal.compare(build, 0) != :gt do
        {:error, :nothing_available}
      else
        convert(kit, build, quantity, location_id, box_id, opts, bottleneck_item(availability))
      end
    end
  end

  defp missing_for(%{bottlenecks: [bottleneck | _]}, quantity) do
    needed = Decimal.mult(bottleneck.needed_per_kit, quantity)
    %{missing: Decimal.sub(needed, bottleneck.available), item: bottleneck.item}
  end

  defp bottleneck_item(%{bottlenecks: [bottleneck | _]}), do: bottleneck.item
  defp bottleneck_item(_availability), do: nil

  defp convert(kit, build, quantity, location_id, box_id, opts, bottleneck) do
    {:ok, picks} = gather_picks(kit, build, location_id)

    Multi.new()
    |> Multi.insert(:lot, fn _changes ->
      Lot.changeset(%Lot{}, %{product_id: kit.product.id, expires_on: earliest_expiry(picks)})
    end)
    |> Multi.run(:transaction, fn _repo, %{lot: lot} ->
      post_conversion(picks, lot, kit, build, location_id, box_id, opts)
    end)
    |> Multi.run(:provenance, fn repo, %{lot: lot} ->
      {:ok, record_provenance(repo, lot, picks)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{lot: lot}} ->
        if Decimal.compare(build, quantity) == :lt do
          {:ok, %{lot: lot, quantity: build, requested: quantity, bottleneck: bottleneck}}
        else
          {:ok, %{lot: lot, quantity: build}}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp earliest_expiry(picks) do
    picks
    |> Enum.map(& &1.expires_on)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> Enum.min(dates, Date)
    end
  end

  defp post_conversion(picks, lot, kit, build, location_id, box_id, opts) do
    component_entries =
      Enum.map(picks, fn pick ->
        %{
          lot_id: pick.lot_id,
          location_id: pick.location_id,
          box_id: pick.box_id,
          quantity: Decimal.negate(pick.take)
        }
      end)

    kit_entry = %{lot_id: lot.id, location_id: location_id, box_id: box_id, quantity: build}

    Inventory.post_transaction(%{
      type: "kit_assembly",
      user_id: opts[:user_id],
      notes:
        opts[:notes] ||
          gettext("Assembly of %{quantity}x %{kit}", quantity: build, kit: kit.name),
      entries: component_entries ++ [kit_entry]
    })
  end

  # One provenance row per distinct component lot consumed, even though a
  # single item can draw from more than one lot to cover `build` kits — the
  # question a recall asks is "how much of lot X ended up in this kit lot",
  # not "which item was it for".
  defp record_provenance(repo, lot, picks) do
    picks
    |> Enum.group_by(& &1.lot_id)
    |> Enum.map(fn {component_lot_id, group} ->
      quantity = Enum.reduce(group, Decimal.new(0), &Decimal.add(&2, &1.take))

      %KitLotProvenance{}
      |> KitLotProvenance.changeset(%{
        kit_lot_id: lot.id,
        component_lot_id: component_lot_id,
        quantity: quantity
      })
      |> repo.insert!()
    end)
  end

  @doc """
  How ready the stock at a location is for the next mission, worst kit first.

  The question a coordinator asks before a trip is not "how much gauze is there"
  — it is "can we build the kits". A warehouse can look full and still be unable
  to complete a single Kit Paciente because one guedel cannula ran out, and a
  units total will never say so.

  Worst first, because a kit that covers nine missions needs no attention and a
  kit that covers none is the whole problem.
  """
  def readiness(location_id) do
    list_kits()
    |> Enum.map(fn kit ->
      availability = availability(kit, location_id)

      %{
        kit: kit,
        possible: availability.possible,
        bottlenecks: availability.bottlenecks,
        unresolved: length(availability.unresolved)
      }
    end)
    |> Enum.sort_by(& &1.possible, &(Decimal.compare(&1, &2) != :gt))
  end

  # Picks every component of `quantity` kits, or explains what is missing.
  defp gather_picks(kit, quantity, location_id) do
    kit.items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, picks} ->
      needed = Decimal.mult(item.quantity, quantity)

      case Inventory.suggest_fefo_positions(item.product_id, needed, location_id: location_id) do
        {:ok, item_picks} ->
          {:cont, {:ok, picks ++ item_picks}}

        {:insufficient_stock, _item_picks, missing} ->
          {:halt, {:error, {:insufficient_stock, %{missing: missing, item: item}}}}
      end
    end)
  end
end
