defmodule EstoqueOS.Inventory.Locations do
  @moduledoc """
  Where the goods physically are: the places, and the boxes that sit in them.

  A location is a warehouse, a mission site, or transit. A box is a movable
  container carrying a code the operation reads off its side.

  This is not the ledger, and the dependency runs one way: moving a box posts a
  transaction through `EstoqueOS.Inventory`, and what a box is presumed to hold
  is read from the ledger's own rollup. Nothing here writes a balance.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Box, Location, Lot, StockSnapshot}
  alias EstoqueOS.Repo

  @doc """
  Locations goods can be received into, warehouses first.
  """
  def list_locations do
    Location
    |> where([l], l.active == true)
    |> order_by([l], asc: l.kind, asc: l.name)
    |> Repo.all()
  end

  @doc """
  Every place the operation has ever had, retired ones included, for the screen
  that manages them.

  A separate function rather than an option on `list_locations/0`: every caller
  of that one is filling a picker, and a picker must never offer a place that
  was deliberately taken out of the operation. Active first, because the retired
  ones are history and the working list is what the screen is for.
  """
  def list_all_locations do
    Location
    |> order_by([l], desc: l.active, asc: l.kind, asc: l.name)
    |> Repo.all()
  end

  @doc """
  The place a load sits while somebody else is driving it.

  There is one, and the load-out needs it by kind rather than by name: "Trânsito"
  is a word on a seed, and a system that finds it by spelling breaks the day
  somebody renames it.
  """
  def transit_location do
    Location
    |> where([l], l.active == true and l.kind == "transit")
    |> order_by([l], asc: l.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  What each location holds, in the terms the operation actually thinks in.

  Boxes, not units: a location's stock travels and is counted as boxes, and a
  unit total summed across gauze and scalpels is a number nobody acts on.

  The value covers only stock whose cost is known. Donations arrive with no
  value informed, and treating those as zero would quietly understate a
  location — `known_value` is named for what it is.
  """
  def location_overview do
    costs = Inventory.average_unit_costs()

    boxes =
      Box
      |> where([b], b.active)
      |> group_by([b], b.location_id)
      |> select([b], {b.location_id, count(b.id)})
      |> Repo.all()
      |> Map.new()

    values =
      StockSnapshot
      |> where([s], s.quantity != 0)
      |> select([s], {s.location_id, s.lot_id, s.quantity})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {location_id, lot_id, quantity}, acc ->
        case costs[lot_id] do
          nil ->
            acc

          cost ->
            Map.update(
              acc,
              location_id,
              Decimal.mult(cost, quantity),
              &Decimal.add(&1, Decimal.mult(cost, quantity))
            )
        end
      end)

    # What is on the floor rather than in a box. The screen needs it to say why
    # a location cannot be retired: "mova as caixas" is the wrong instruction
    # for a place whose stock was never in one.
    loose =
      StockSnapshot
      |> where([s], is_nil(s.box_id) and s.quantity != 0)
      |> group_by([s], s.location_id)
      |> select([s], {s.location_id, sum(s.quantity)})
      |> Repo.all()
      |> Map.new()

    Location
    |> select([l], l.id)
    |> Repo.all()
    |> Map.new(fn id ->
      {id,
       %{
         boxes: Map.get(boxes, id, 0),
         loose: Map.get(loose, id, Decimal.new(0)),
         known_value: Map.get(values, id, Decimal.new(0))
       }}
    end)
  end

  @doc """
  Retires a location without erasing where stock has been.

  There is no `delete_location`: transactions name the location they moved stock
  from and to, so removing the row would tear a hole in the audit trail this
  system exists to keep. Deactivating drops it out of `list_locations/0`, and
  therefore out of every picker, while the history stays readable.
  """
  def deactivate_location(%Location{} = location) do
    if empty?(location) do
      location |> Location.changeset(%{active: false}) |> Repo.update()
    else
      # Not a validation on the changeset: what makes a location retirable is a
      # fact about the ledger, not about the row. Refused here so a
      # hand-crafted event cannot retire a place that still holds goods and
      # take that stock out of every picker with it.
      {:error, :not_empty}
    end
  end

  @doc """
  Puts a retired location back into the operation.

  The mission that ran last year runs again, and re-registering it under the
  same name is not possible — the name is unique, and the row that owns it is
  the one holding all the history. So the way back is this, not a second row.
  """
  def reactivate_location(%Location{} = location) do
    location |> Location.changeset(%{active: true}) |> Repo.update()
  end

  @doc """
  Whether a location holds nothing at all: no active box, no stock loose on its
  floor.

  Boxes alone were the old question, and stock can sit at a location without
  one — every manual entry with the box field left blank puts it there.
  """
  def empty?(%Location{} = location), do: empty?(location.id)

  def empty?(location_id) do
    not Repo.exists?(from b in Box, where: b.location_id == ^location_id and b.active) and
      not Repo.exists?(
        from s in StockSnapshot, where: s.location_id == ^location_id and s.quantity != 0
      )
  end

  @doc """
  Active boxes at a location, by code.
  """
  def list_boxes(location_id) do
    Box
    |> where([b], b.location_id == ^location_id and b.active)
    |> order_by([b], asc: b.code)
    |> Repo.all()
  end

  @doc """
  The location the import screen preselects.

  Configured with `config :estoque_os, :default_location_name`; falls back to
  the first active warehouse so a fresh install still works.
  """
  def default_location(segment \\ nil) do
    for_segment(segment) || configured_location() || first_warehouse()
  end

  # The place the operation says goods of this stock arrive at. Marketing
  # material comes into the office and surgical supplies into the warehouse, and
  # before this every screen preselected the same one for both — which is the
  # location the marketing coordinator had to correct on every single entry.
  defp for_segment(nil), do: nil

  defp for_segment(segment) do
    Location
    |> where([l], l.active == true and l.default_for_segment == ^segment)
    |> Repo.one()
  end

  defp configured_location do
    name = Application.get_env(:estoque_os, :default_location_name)

    name &&
      Location
      |> where([l], l.active == true and fragment("lower(?)", l.name) == ^String.downcase(name))
      |> Repo.one()
  end

  defp first_warehouse do
    Location
    |> where([l], l.active == true and l.kind == "warehouse")
    |> order_by([l], asc: l.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Makes a place the default entry point for one stock, or takes the mark off.

  One per stock: setting a new one clears whichever place held it, because two
  places both claiming to be where marketing material arrives is a question the
  screens would end up answering by row id.
  """
  def set_default_for_segment(%Location{} = location, segment) do
    Repo.transaction(fn ->
      if segment do
        Location
        |> where([l], l.default_for_segment == ^segment and l.id != ^location.id)
        |> Repo.update_all(set: [default_for_segment: nil, updated_at: DateTime.utc_now(:second)])
      end

      location
      |> Location.changeset(%{default_for_segment: segment})
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def get_location!(id), do: Repo.get!(Location, id)

  def create_location(attrs), do: %Location{} |> Location.changeset(attrs) |> Repo.insert()

  def update_location(%Location{} = location, attrs) do
    location |> Location.changeset(attrs) |> Repo.update()
  end

  def change_location(%Location{} = location, attrs \\ %{}) do
    Location.changeset(location, attrs)
  end

  def get_box!(id), do: Box |> Repo.get!(id) |> Repo.preload(:location)

  @doc "The box wearing this code, anywhere, or nil."
  def get_box_by_code(code), do: Repo.get_by(Box, code: String.trim(to_string(code)))

  def create_box(attrs), do: %Box{} |> Box.changeset(attrs) |> Repo.insert()

  @doc """
  Turns whatever somebody typed into a box picker into a box at this location.

  Four answers, and each one is a real thing that happens in a warehouse:

    * blank — the goods are loose, which is legitimate and stays legitimate
    * a code that is here — the ordinary case
    * a code that exists somewhere else — refused, because a box is a physical
      object and it cannot be in two rooms; move it first
    * a code nobody has registered — created here, and the caller says so out
      loud

  That last one is the "poder criar caixa" the field asked for: the operator is
  holding a box with `AN07` written on it and the system has never heard of it.
  Refusing them at that moment is how a warehouse ends up with goods recorded
  as loose forever. It is announced rather than silent so a typo shows up
  immediately, and nothing is destroyed if one gets through — an unwanted box
  is deactivated, like everything else here.

  ## Asking first

  Announcing the creation afterwards turned out not to be enough. `CX-102` typed
  where `CX-012` was meant is a box that exists, is empty, is never opened, and
  quietly holds the difference in somebody's stock. The flash saying it was
  created arrives after the goods are already in it.

  So `create: false` stops short and answers `{:unknown, code}` instead: the
  code is not here, nothing has been written, ask the operator whether they
  meant it. Calling again with the default `create: true` is the yes.
  """
  def resolve_box(code, location_id, opts \\ []) do
    case String.trim(to_string(code)) do
      "" ->
        {:ok, nil}

      code ->
        case Repo.get_by(Box, code: code) do
          nil -> resolve_unknown(code, location_id, Keyword.get(opts, :create, true))
          %Box{location_id: ^location_id} = box -> {:ok, box}
          %Box{} = elsewhere -> {:error, {:box_elsewhere, elsewhere}}
        end
    end
  end

  defp resolve_unknown(code, location_id, true), do: create_box_at(code, location_id)
  defp resolve_unknown(code, _location_id, false), do: {:unknown, code}

  defp create_box_at(code, location_id) do
    case create_box(%{code: code, location_id: location_id}) do
      {:ok, box} -> {:created, box}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def change_box(%Box{} = box, attrs \\ %{}), do: Box.changeset(box, attrs)

  @doc """
  Stock at a location that is in no box, per lot, soonest expiry first.

  A real and temporary state: goods arrived and nobody has boxed them yet. It is
  temporary because loose stock cannot travel — nothing identifies it at the
  other end and nothing brings it back — so a load-out refuses it, and this list
  is what a person works through to make the load possible.
  """
  def loose_stock(location_id) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> where([s], s.location_id == ^location_id and is_nil(s.box_id) and s.quantity != 0)
    |> order_by([s, l, p], asc_nulls_last: l.expires_on, asc: p.name)
    |> select([s, l, p], %{
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      product_id: p.id,
      product: p.name,
      controlled: p.controlled,
      quantity: s.quantity
    })
    |> Repo.all()
  end

  @doc """
  Puts loose stock into a box, at the location the box is already at.

  The question this answers — "how do I get a product with no box into one?" —
  had no answer at all: `rebox/5` needs a box to take the goods *out* of, and
  loose stock is exactly the stock that has none. So goods that arrived through
  a manual entry with the box left blank, or through a spreadsheet count, sat
  where no load-out would carry them and no screen would move them.

  Mechanically it is the same movement as re-boxing and it is one for the same
  reason: a `transfer` whose two entries share a location and differ only in the
  box. Nothing leaves the room, so no balance at the location moves — only where
  inside it the goods sit.

  `last_verified_at` is left alone. Putting things into a box tells us nothing
  about whether the count in it was right.
  """
  def put_in_box(%Box{} = box, lot_id, quantity, opts \\ []) do
    lot_id = to_id(lot_id)
    quantity = to_decimal(quantity)
    available = Inventory.balance(lot_id: lot_id, location_id: box.location_id, box_id: nil)

    cond do
      is_nil(quantity) or Decimal.compare(quantity, 0) != :gt ->
        {:error, :invalid_quantity}

      Decimal.compare(quantity, available) == :gt ->
        {:error, {:insufficient_stock, %{available: available}}}

      true ->
        Inventory.post_transaction(%{
          type: "transfer",
          source_location_id: box.location_id,
          destination_location_id: box.location_id,
          user_id: opts[:user_id],
          notes: opts[:notes] || gettext("loose → %{box}", box: box.code),
          entries: [
            %{
              lot_id: lot_id,
              box_id: nil,
              location_id: box.location_id,
              quantity: Decimal.negate(quantity)
            },
            %{
              lot_id: lot_id,
              box_id: box.id,
              location_id: box.location_id,
              quantity: quantity
            }
          ]
        })
    end
  end

  @doc """
  Moves goods from one box into another at the same location.

  Re-boxing is an everyday warehouse act — two half-empty boxes become one, a
  product ends up where its group lives — and until this existed a lot's box was
  fixed at the moment it entered. The shelf changed and the ledger did not,
  which is the drift that makes a stock unauditable.

  Nothing new in the schema: it is a `transfer` whose two entries share a
  location and differ only in the box. The goods never leave the room, so no
  balance at the location moves — only where inside it they sit.

  Part of a lot may move; the quantity is checked against what the source box
  actually holds, because a box cannot lend what it does not have.

  Neither box is marked as verified. Moving things between boxes tells us
  nothing about whether the count was right, and stamping it would launder a
  presumption into a verification.
  """
  def rebox(%Box{} = from, %Box{} = to, lot_id, quantity, opts \\ []) do
    lot_id = to_id(lot_id)
    quantity = to_decimal(quantity)
    available = Inventory.balance(lot_id: lot_id, box_id: from.id)

    cond do
      from.id == to.id ->
        {:error, :same_box}

      from.location_id != to.location_id ->
        {:error, :different_locations}

      is_nil(quantity) or Decimal.compare(quantity, 0) != :gt ->
        {:error, :invalid_quantity}

      Decimal.compare(quantity, available) == :gt ->
        {:error, {:insufficient_stock, %{available: available}}}

      true ->
        Inventory.post_transaction(%{
          type: "transfer",
          source_location_id: from.location_id,
          destination_location_id: to.location_id,
          user_id: opts[:user_id],
          notes: opts[:notes] || gettext("%{from} → %{to}", from: from.code, to: to.code),
          entries: [
            %{
              lot_id: lot_id,
              box_id: from.id,
              location_id: from.location_id,
              quantity: Decimal.negate(quantity)
            },
            %{
              lot_id: lot_id,
              box_id: to.id,
              location_id: to.location_id,
              quantity: quantity
            }
          ]
        })
    end
  end

  @doc """
  Every box, with where it is and how much it is presumed to hold.
  """
  def list_boxes_with_contents do
    quantities =
      StockSnapshot
      |> where([s], not is_nil(s.box_id) and s.quantity != 0)
      |> group_by([s], s.box_id)
      |> select([s], {s.box_id, %{quantity: sum(s.quantity), positions: count(s.id)}})
      |> Repo.all()
      |> Map.new()

    Box
    |> where([b], b.active)
    |> order_by([b], asc: b.code)
    |> preload(:location)
    |> Repo.all()
    |> Enum.map(fn box ->
      contents = Map.get(quantities, box.id, %{quantity: Decimal.new(0), positions: 0})
      Map.merge(%{box: box}, contents)
    end)
  end

  @doc """
  What a box is presumed to hold, per lot.

  "Presumed" is the honest word: a box moves without being recounted, so these
  numbers are only as fresh as `last_verified_at` says.
  """
  def box_contents(%Box{} = box) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> where([s], s.box_id == ^box.id and s.quantity != 0)
    |> order_by([s, l, p], asc: p.name, asc_nulls_last: l.expires_on)
    |> select([s, l, p], %{
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      product: p.name,
      # A kit can carry a Portaria 344 item, and whoever opens the box has to
      # know that before it travels.
      controlled: p.controlled,
      location_id: s.location_id,
      quantity: s.quantity
    })
    |> Repo.all()
  end

  @doc """
  Boxes worth putting this product in, and why.

  When a delivery lands, the question is not "which boxes exist" — it is "where
  does this belong". A warehouse organised by whoever was holding the scanner is
  a warehouse where finding anything means opening everything.

  Ranked by how strong the reason is. A box already holding this exact product is
  the obvious answer: splitting one product across two boxes is how a recall
  finds half of it. Then the same group, then the same sector, which is how the
  standard supply table already thinks — "ANESTESIA - MEDICAMENTOS" is a shelf in
  somebody's head before it is a column in a spreadsheet.

  Every suggestion carries its reason, because a list of box codes with no
  explanation is a list nobody trusts enough to follow.
  """
  def suggest_boxes(product_id, location_id, opts \\ []) do
    product = Repo.get(Product, product_id)

    if product do
      contents(location_id)
      |> Enum.group_by(& &1.box_id)
      |> Enum.map(fn {_box_id, rows} -> best_reason(product, rows) end)
      |> Enum.reject(&is_nil(&1.reason))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(opts[:limit] || 3)
    else
      []
    end
  end

  defp contents(location_id) do
    StockSnapshot
    |> join(:inner, [s], b in Box, on: b.id == s.box_id)
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, _b, l], p in Product, on: p.id == l.product_id)
    # Both sides, deliberately. `enter_manually/1` refuses a box that sits
    # somewhere else, but `post_transaction/1` does not, so a suggestion built on
    # the position alone could offer a box that is not even in the building.
    |> where(
      [s, b],
      s.location_id == ^location_id and b.location_id == ^location_id and s.quantity != 0 and
        b.active
    )
    |> select([s, b, _l, p], %{
      box_id: b.id,
      box: b,
      product_id: p.id,
      product: p.name,
      group_id: p.product_group_id,
      sector: p.sector
    })
    |> Repo.all()
  end

  # The strongest reason a box has for holding this product, if it has one.
  defp best_reason(product, [%{box: box} | _] = rows) do
    cond do
      match = Enum.find(rows, &(&1.product_id == product.id)) ->
        %{box: box, score: 3, reason: :same_product, because: match.product}

      match =
          product.product_group_id && Enum.find(rows, &(&1.group_id == product.product_group_id)) ->
        %{box: box, score: 2, reason: :same_group, because: match.product}

      match = product.sector && Enum.find(rows, &(&1.sector == product.sector)) ->
        %{box: box, score: 1, reason: :same_sector, because: match.sector}

      true ->
        %{box: box, score: 0, reason: nil, because: nil}
    end
  end

  @doc """
  What matters about several boxes at once, without reading their contents.

  Returns a map of `box_id` to the number of stock positions, the earliest expiry
  among them and whether any of it is controlled. That is everything a listing
  shows about a box, and asking `box_contents/1` per row to get it turns one
  screen into one query per box.

  `min` over the expiry skips nulls in SQL, which is the answer wanted: a lot with
  no expiry on record is not the earliest expiry, it is an unknown one.
  """
  def box_summaries(box_ids) when is_list(box_ids) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> where([s], s.box_id in ^box_ids and s.quantity != 0)
    |> group_by([s], s.box_id)
    |> select([s, l, p], %{
      box_id: s.box_id,
      positions: count(s.id),
      expires_on: min(l.expires_on),
      controlled: fragment("bool_or(?)", p.controlled)
    })
    |> Repo.all()
    |> Map.new(&{&1.box_id, &1})
  end

  @doc """
  Moves a whole box to another location, contents and all.

  This is the cheap operation the operation actually needs: a box goes from the
  warehouse to a mission, or straight from one mission to the next, without
  anybody opening it. The ledger records the movement of its *presumed*
  contents and `last_verified_at` is deliberately left alone — moving a box
  tells us nothing new about what is inside it. Divergences surface at the
  next count, wherever that happens.

  A location of kind `transit` is what "estoque em trânsito" means here: the
  goods left one place and have not arrived at the next.
  """
  def move_box(%Box{} = box, destination_location_id, opts \\ []) do
    destination_location_id = to_id(destination_location_id)

    cond do
      box.location_id == destination_location_id ->
        {:error, :same_location}

      not movable_by_hand?(destination_location_id) ->
        {:error, :load_out_required}

      true ->
        Multi.new()
        |> maybe_post_move(box, destination_location_id, opts)
        |> Multi.update(:box, Box.changeset(box, %{location_id: destination_location_id}))
        |> Repo.transaction()
        |> case do
          {:ok, changes} ->
            {:ok,
             %{
               box: Repo.preload(changes.box, :location, force: true),
               transaction: changes[:transaction]
             }}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  # Which moves a person may make from the Boxes screen, and which have to go
  # through the load-out.
  #
  # Between missions a box crosses the warehouse floor dozens of times, and
  # demanding a load-out for each of those is how people stop using the system.
  # But a box arriving at a mission, or entering transit, is the moment the
  # movement acquires a *reason* — which trip it belongs to — and only the
  # load-out asks. A box teleported there by one click is stock nobody can
  # attribute afterwards.
  #
  # Enforced here rather than in the select: a rule the ledger depends on cannot
  # live in a template.
  defp movable_by_hand?(nil), do: false

  defp movable_by_hand?(location_id) do
    case Repo.get(Location, location_id) do
      nil -> false
      %Location{kind: kind} -> kind not in ~w(mission_site transit)
    end
  end

  # An empty box changes address without the ledger hearing about it. There is
  # nothing to move, and a transaction carrying no entries is a record of nothing
  # having happened — noise in the one place that has to stay readable.
  defp maybe_post_move(multi, box, destination_location_id, opts) do
    case move_entries(box, destination_location_id) do
      [] ->
        multi

      entries ->
        Multi.run(multi, :transaction, fn _repo, _changes ->
          Inventory.post_transaction(%{
            type: "transfer",
            source_location_id: box.location_id,
            destination_location_id: destination_location_id,
            user_id: opts[:user_id],
            notes: opts[:notes],
            entries: entries
          })
        end)
    end
  end

  defp move_entries(box, destination_location_id) do
    StockSnapshot
    |> where([s], s.box_id == ^box.id and s.quantity != 0)
    |> select([s], %{lot_id: s.lot_id, location_id: s.location_id, quantity: s.quantity})
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      [
        %{
          lot_id: row.lot_id,
          box_id: box.id,
          location_id: row.location_id,
          quantity: Decimal.negate(row.quantity)
        },
        %{
          lot_id: row.lot_id,
          box_id: box.id,
          location_id: destination_location_id,
          quantity: row.quantity
        }
      ]
    end)
  end

  @doc """
  Records that a box was physically checked, without changing any quantity.
  """
  def mark_box_verified(%Box{} = box) do
    box
    |> Box.changeset(%{last_verified_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end
end
