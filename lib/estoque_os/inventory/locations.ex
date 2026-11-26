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
  Every place ever, retired included, active first, for the management screen.

  Separate from `list_locations/0` because pickers must never offer a retired place.
  """
  def list_all_locations do
    Location
    |> order_by([l], desc: l.active, asc: l.kind, asc: l.name)
    |> Repo.all()
  end

  @doc """
  The place a load sits while somebody else is driving it.

  Found by kind, not name, so renaming "Trânsito" does not break the load-out.
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

  Boxes, not units: stock travels and is counted as boxes.

  The value covers only stock whose cost is known; donations have none, and
  counting them as zero would understate a location.
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

    # Stock on the floor, so the screen can say why a location cannot be retired.
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

  There is no `delete_location`: transactions reference locations. Deactivating
  drops it from every picker while history stays readable.
  """
  def deactivate_location(%Location{} = location) do
    if empty?(location) do
      location |> Location.changeset(%{active: false}) |> Repo.update()
    else
      # Checked here, not in the changeset: retirability is a fact about the ledger.
      {:error, :not_empty}
    end
  end

  @doc """
  Puts a retired location back into the operation.

  Not a second row: the name is unique and the original row holds the history.
  """
  def reactivate_location(%Location{} = location) do
    location |> Location.changeset(%{active: true}) |> Repo.update()
  end

  @doc """
  Whether a location holds nothing: no active box and no loose stock (a manual
  entry with the box left blank puts stock there without one).
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

  One per stock: setting a new one clears the previous holder.
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
  def get_box_by_code(code) do
    case normalize_code(code) do
      "" -> nil
      code -> Repo.get_by(Box, code: code)
    end
  end

  # Box.changeset stores codes trimmed and upcased; a raw lookup would miss the box.
  defp normalize_code(code), do: code |> to_string() |> String.trim() |> String.upcase()

  def create_box(attrs), do: %Box{} |> Box.changeset(attrs) |> Repo.insert()

  @doc """
  Turns whatever somebody typed into a box picker into a box at this location.

  Four answers:

    * blank — the goods are loose, which is legitimate
    * a code that is here — the ordinary case
    * a code that exists elsewhere — refused: a box cannot be in two places; move it first
    * a code nobody has registered — created here, and the caller announces it

  Creating on the spot is deliberate: refusing an unknown box in the operator's
  hands leaves goods recorded as loose forever.

  `create: false` stops short with `{:unknown, code}` and writes nothing, so the
  caller can ask first (a typo like `CX-102` for `CX-012` would otherwise create
  a box that quietly holds the difference). Calling again with the default
  `create: true` is the yes.
  """
  def resolve_box(code, location_id, opts \\ []) do
    case normalize_code(code) do
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

  Loose stock cannot travel (nothing identifies it at the other end), so a
  load-out refuses it; this list is what a person works through first.
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

  `rebox/5` needs a source box, which loose stock lacks. Same movement as
  re-boxing: a `transfer` whose entries share a location and differ only in the
  box, so no location balance moves.

  `last_verified_at` is left alone: boxing says nothing about the count.
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

  A `transfer` whose entries share a location and differ only in the box, so
  the ledger follows the shelf and no location balance moves.

  Part of a lot may move; the quantity is checked against the source box.

  Neither box is marked verified: that would launder a presumption into a
  verification.
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
  Moves everything a box holds into another box at the same location, in one
  `transfer`.

  The point of this over `rebox/5` one lot at a time: a worn-out box is emptied
  into a fresh one in a single act, atomically, so the source is never left
  half-moved. `last_verified_at` is left alone on both, as re-boxing says
  nothing about the count.
  """
  def empty_box_into(%Box{} = from, %Box{} = to, opts \\ []) do
    cond do
      from.id == to.id ->
        {:error, :same_box}

      from.location_id != to.location_id ->
        {:error, :different_locations}

      true ->
        case rebox_all_entries(from, to) do
          [] ->
            {:error, :empty_box}

          entries ->
            Inventory.post_transaction(%{
              type: "transfer",
              source_location_id: from.location_id,
              destination_location_id: to.location_id,
              user_id: opts[:user_id],
              notes:
                opts[:notes] ||
                  gettext("%{from} emptied into %{to}", from: from.code, to: to.code),
              entries: entries
            })
        end
    end
  end

  defp rebox_all_entries(from, to) do
    StockSnapshot
    |> where([s], s.box_id == ^from.id and s.quantity != 0)
    |> select([s], %{lot_id: s.lot_id, location_id: s.location_id, quantity: s.quantity})
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      [
        %{
          lot_id: row.lot_id,
          box_id: from.id,
          location_id: row.location_id,
          quantity: Decimal.negate(row.quantity)
        },
        %{
          lot_id: row.lot_id,
          box_id: to.id,
          location_id: row.location_id,
          quantity: row.quantity
        }
      ]
    end)
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

  Presumed: a box moves without being recounted, so these numbers are only as
  fresh as `last_verified_at`.
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
      # A kit can carry a Portaria 344 (controlled) item; the box opener must know.
      controlled: p.controlled,
      location_id: s.location_id,
      quantity: s.quantity
    })
    |> Repo.all()
  end

  @doc """
  Boxes worth putting this product in, and why.

  Ranked by reason strength: a box already holding this product (splitting one
  product across boxes makes a recall find half of it), then the same group,
  then the same sector (how the standard supply table is organised). Every
  suggestion carries its reason.
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
    # Check both sides: `post_transaction/1` does not refuse a box elsewhere, so
    # the position alone could suggest a box that is not in the building.
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

  Returns `box_id` to position count, earliest expiry and whether any is
  controlled, avoiding one `box_contents/1` query per row. `min` skips nulls: an
  unknown expiry is not the earliest.
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

  The ledger records the movement of its *presumed* contents; `last_verified_at`
  is left alone and divergences surface at the next count.

  A `transit` location is "estoque em trânsito": left one place, not yet arrived.
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

  # Moves to a mission site or transit must go through the load-out, which
  # records the trip; anything else is cheap enough to do by hand. Enforced here
  # because a rule the ledger depends on cannot live in a template.
  defp movable_by_hand?(nil), do: false

  defp movable_by_hand?(location_id) do
    case Repo.get(Location, location_id) do
      nil -> false
      %Location{kind: kind} -> kind not in ~w(mission_site transit)
    end
  end

  # An empty box posts nothing: a transaction with no entries is noise in the ledger.
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

  @doc """
  Gives a box a new code.

  The code is the box's name on the shelf, so a box put under a code that makes
  no sense is corrected here. `Box.changeset` upcases and trims it and refuses a
  code another box already wears.
  """
  def rename_box(%Box{} = box, code) do
    box |> Box.changeset(%{code: code}) |> Repo.update()
  end

  @doc """
  Takes a worn-out box out of use without deleting it.

  It keeps its whole history but stops showing up in listings and pickers
  (`active: false`). Refused while it still holds stock: a retired box that held
  anything would hide that stock from every box view, so it is emptied first.
  """
  def retire_box(%Box{} = box) do
    if box_empty?(box) do
      box |> Box.changeset(%{active: false}) |> Repo.update()
    else
      {:error, :not_empty}
    end
  end

  @doc "Puts a retired box back into use."
  def reopen_box(%Box{} = box) do
    box |> Box.changeset(%{active: true}) |> Repo.update()
  end

  defp box_empty?(%Box{} = box) do
    not (StockSnapshot
         |> where([s], s.box_id == ^box.id and s.quantity != 0)
         |> Repo.exists?())
  end
end
