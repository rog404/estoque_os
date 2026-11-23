defmodule EstoqueOS.Kits do
  @moduledoc """
  Kits: the bills of materials a mission works in.

  A kit is a product like any other (`products.kit_id`): searchable, issuable,
  reportable. `assemble/3` is the one operation that converts a recipe's
  components into a new lot of it; after that it is handled like a box of gauze.

  `KitLotProvenance` records which component lots built a kit lot, for recalls.

  A kit line with no resolved product blocks assembly loudly: silently skipping
  an unrecognized line is how a kit ships without its guedel cannula.
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

  def get_kit!(id), do: Kit |> Repo.get!(id) |> load_kit()

  def list_kits do
    Kit
    |> where([k], k.active)
    |> order_by([k], asc: k.name)
    |> Repo.all()
    |> Enum.map(&load_kit/1)
  end

  # Order is the order components are read, packed and reported in, and
  # `assemble/3` names the *first* short one. `KitItem` has no position, so id
  # order is the spreadsheet's order.
  defp load_kit(kit) do
    Repo.preload(kit, [:product, items: {from(i in KitItem, order_by: [asc: i.id]), :product}],
      force: true
    )
  end

  @doc """
  Creates a kit and the catalog product that represents it; a kit is never
  without one.
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
  Renames a kit and its product together; otherwise the write-off screen would
  show the old name.
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

    # A hand-added line must name a catalog product: free text cannot be
    # counted, packed or consumed. Enforced here, not in the changeset, because
    # the importer records spreadsheet lines unresolved.
    cond do
      blank?(attrs["product_id"]) ->
        {:error,
         %KitItem{}
         |> KitItem.changeset(attrs)
         |> Ecto.Changeset.add_error(:product_id, "must name a catalog product")}

      # The same product twice would make `availability/2` count its stock
      # against each line separately; the existing line's quantity is the thing to change.
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

  Hard-deleted, unlike the ledger: a recipe line is an edit to a document, not a
  record of something that happened. What was built lives in transactions and lots.
  """
  def remove_kit_item(%KitItem{} = item) do
    with {:ok, deleted} <- Repo.delete(item) do
      deleted.kit_id |> get_kit!() |> sync_controlled()
      {:ok, deleted}
    end
  end

  # A kit is controlled (Portaria 344) because of what is in it; recomputed on
  # every recipe edit, never chosen.
  defp sync_controlled(%Kit{} = kit) do
    kit = load_kit(kit)
    controlled? = Enum.any?(kit.items, &(&1.product && &1.product.controlled))

    {:ok, _product} =
      kit.product |> Product.changeset(%{controlled: controlled?}) |> Repo.update()

    :ok
  end

  @doc """
  How many of this kit are in stock, anywhere.

  The kit's own product balance, as for any product.
  """
  def assembled_count(%Kit{} = kit), do: Inventory.balance(product_id: kit.product.id)

  @doc "Kit lines that still have no product in the catalog."
  def unresolved_items(%Kit{} = kit), do: Enum.filter(kit.items, &is_nil(&1.product_id))

  @doc """
  How many complete kits the stock at a location can cover, and what runs out
  first.

  The bottleneck is the useful half: it is the shopping list.
  """
  def availability(%Kit{} = kit, location_id) do
    resolved = Enum.filter(kit.items, & &1.product_id)

    # One query for the whole bill of materials, not one per line.
    balances =
      resolved
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()
      |> Inventory.balances_by_product(location_id)

    # Expired stock blocks assembly (see `assemble/3`); screens must be able to say why.
    expired =
      resolved
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()
      |> Inventory.expired_balances_by_product(location_id)

    lines =
      Enum.map(resolved, fn item ->
        available = Map.get(balances, item.product_id) || Decimal.new(0)
        possible = Decimal.div(available, item.quantity) |> Decimal.round(0, :down)

        %{
          item: item,
          available: available,
          needed_per_kit: item.quantity,
          possible: possible,
          expired: Map.get(expired, item.product_id)
        }
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
      unresolved: unresolved_items(kit),
      expired_components: Enum.filter(lines, & &1.expired)
    }
  end

  @doc """
  Where each resolved component of a kit is, box by box, at a location.

  The conference before assembling: where to find what `availability/2` counted.
  Unresolved lines are left out; they already block assembly.
  """
  def box_breakdown(%Kit{} = kit, location_id) do
    kit.items
    |> Enum.filter(& &1.product_id)
    |> Map.new(fn item -> {item.id, Inventory.box_quantities(item.product_id, location_id)} end)
  end

  @doc """
  The conference for a requested `quantity`: how much each component needs,
  against what `availability/2` found, and where to find it per `box_breakdown/2`.
  """
  def review_lines(%{lines: lines}, quantity, breakdown) do
    Enum.map(lines, fn line ->
      needed = Decimal.mult(line.item.quantity, quantity)

      %{
        item: line.item,
        needed: needed,
        available: line.available,
        short?: Decimal.compare(line.available, needed) == :lt,
        expired: line.expired,
        boxes: Map.get(breakdown, line.item.id, [])
      }
    end)
  end

  @doc """
  Converts `quantity` kits' worth of components into that quantity of the
  kit's own product, in one new lot, in `box_id`.

  Manufacturing, not packing: components leave stock for good, drawn FEFO, and
  a lot of the kit appears in the box.

  A kit is never partially built: asking for more than the components cover is
  refused unless `allow_partial`, which builds as many whole kits as it can and
  says what stopped the rest.
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

    cond do
      # First, with no override: a kit is sealed and nobody reopens it to check
      # a date, and FEFO reaches for the expired lot first. The remedy is a
      # write-off with a reason code, which leaves a record a suppressed warning would not.
      availability.expired_components != [] ->
        {:error, {:expired_components, availability.expired_components}}

      Decimal.compare(possible, quantity) == :lt and !opts[:allow_partial] ->
        {:error, {:insufficient_stock, missing_for(availability, quantity)}}

      true ->
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
    # The shelf can change since `availability/2`; a short pick is the usual
    # insufficient-stock answer, not a crash.
    case gather_picks(kit, build, location_id) do
      {:ok, picks} ->
        post_assembly(kit, picks, build, quantity, location_id, box_id, opts, bottleneck)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_assembly(kit, picks, build, quantity, location_id, box_id, opts, bottleneck) do
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

  # One row per distinct component lot: a recall asks how much of lot X went
  # into this kit lot, not which item it was for.
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

  The pre-trip question is "can we build the kits", not "how much gauze": a full
  warehouse can still be one cannula short of a kit. Worst first.
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
