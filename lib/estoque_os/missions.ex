defmodule EstoqueOS.Missions do
  @moduledoc """
  Surgical trips, and what each one did to the stock.

  A lens over the ledger that groups what left, came back, was used and was
  donated by trip rather than by day.

  Movements carry `mission_id`, stamped when they happen. Nothing is re-derived
  at read time from dates that may have shifted.
  """

  import Ecto.Query

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.{Location, Lot, StockSnapshot, Transaction, TransactionEntry}
  alias EstoqueOS.Missions.Mission
  alias EstoqueOS.Repo
  alias EstoqueOS.Reports

  @doc "Missions, most recent departure first."
  def list_missions do
    Mission
    |> order_by([m], desc: m.starts_on, desc: m.id)
    |> preload(:location)
    |> Repo.all()
  end

  @doc "One mission with its location loaded."
  def get_mission!(id), do: Mission |> Repo.get!(id) |> Repo.preload(:location)

  def create_mission(attrs), do: %Mission{} |> Mission.changeset(attrs) |> Repo.insert()

  def update_mission(%Mission{} = mission, attrs) do
    mission |> Mission.changeset(attrs) |> Repo.update()
  end

  def change_mission(%Mission{} = mission, attrs \\ %{}), do: Mission.changeset(mission, attrs)

  @doc """
  The mission a movement at this location belongs to.

  Mission dates are for people to read, not a gate: load-outs are prepared
  before departure and boxes come home after the return date, so attributing
  goods by comparing dates to the clock would misfile them.

  The answer comes from the place: the most recent trip to have *started* there
  (not merely registered, or a future trip would collect the late returns of the
  real one). A not-yet-started trip is the answer only when no trip ever
  started: goods can be staged before the first mission. Trips at one place
  cannot overlap, so the latest started is the open one. `nil` for a warehouse.
  """
  def for_location(nil), do: nil

  def for_location(location_id) do
    today = Date.utc_today()

    started =
      Mission
      |> where([m], m.location_id == ^location_id and m.starts_on <= ^today)
      |> order_by([m], desc: m.starts_on, desc: m.id)
      |> limit(1)
      |> Repo.one()

    started ||
      Mission
      |> where([m], m.location_id == ^location_id)
      |> order_by([m], asc: m.starts_on, asc: m.id)
      |> limit(1)
      |> Repo.one()
  end

  @doc """
  What the mission did to the stock, product by product.

  Per line:

    * `sent` — what arrived for this trip (the arriving half of a load-out,
      read at the mission's own location)
    * `returned` — what came back
    * `consumed` — what was used during the mission
    * `donated` — what was handed over at the end, not the same as used
    * `handed_on` — what went straight to the next mission without coming home

  `unaccounted` is `sent` minus the other four: usually zero, otherwise stock
  the ledger cannot place.
  """
  def panel(%Mission{} = mission) do
    rows =
      TransactionEntry
      |> join(:inner, [e], t in Transaction, on: t.id == e.transaction_id)
      |> join(:inner, [e, t], l in Lot, on: l.id == e.lot_id)
      |> join(:inner, [e, t, l], p in Product, on: p.id == l.product_id)
      |> where([e], e.location_id == ^mission.location_id)
      |> where(
        [e, t],
        t.mission_id == ^mission.id or
          (t.source_mission_id == ^mission.id and t.type == "load_out")
      )
      |> select([e, t, l, p], %{
        product_id: p.id,
        product: p.name,
        controlled: p.controlled,
        type: t.type,
        destination: t.destination,
        mission_id: t.mission_id,
        quantity: e.quantity
      })
      |> Repo.all()

    lines =
      rows
      |> Enum.group_by(& &1.product_id)
      |> Enum.map(fn {_product_id, entries} -> line(entries, mission.id) end)
      |> Enum.sort_by(& &1.product)

    %{mission: mission, lines: lines, totals: totals(lines), still_there: still_there(mission)}
  end

  defp line([first | _] = entries, mission_id) do
    # A load-out here is an arrival for this mission, a departure for the next.
    sent = sum(entries, &(&1.type == "load_out" and &1.mission_id == mission_id))
    handed_on = sum(entries, &(&1.type == "load_out" and &1.mission_id != mission_id))
    returned = sum(entries, &(&1.type == "return_in"))
    donated = sum(entries, &(&1.type == "manual_out" and &1.destination == "donation"))

    consumed =
      sum(entries, fn row ->
        row.type == "kit_consumption" or
          (row.type == "manual_out" and row.destination != "donation")
      end)

    %{
      product_id: first.product_id,
      product: first.product,
      controlled: first.controlled,
      sent: Decimal.abs(sent),
      returned: Decimal.abs(returned),
      consumed: Decimal.abs(consumed),
      donated: Decimal.abs(donated),
      handed_on: Decimal.abs(handed_on),
      unaccounted:
        [returned, consumed, donated, handed_on]
        |> Enum.map(&Decimal.abs/1)
        |> Enum.reduce(Decimal.abs(sent), &Decimal.sub(&2, &1))
    }
  end

  defp sum(entries, matches?) do
    entries
    |> Enum.filter(matches?)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.quantity))
  end

  defp totals(lines) do
    Enum.reduce(
      lines,
      %{
        sent: Decimal.new(0),
        returned: Decimal.new(0),
        consumed: Decimal.new(0),
        donated: Decimal.new(0),
        handed_on: Decimal.new(0),
        unaccounted: Decimal.new(0),
        controlled_lines: 0
      },
      fn line, acc ->
        acc
        |> Map.update!(:sent, &Decimal.add(&1, line.sent))
        |> Map.update!(:returned, &Decimal.add(&1, line.returned))
        |> Map.update!(:consumed, &Decimal.add(&1, line.consumed))
        |> Map.update!(:donated, &Decimal.add(&1, line.donated))
        |> Map.update!(:handed_on, &Decimal.add(&1, line.handed_on))
        |> Map.update!(:unaccounted, &Decimal.add(&1, line.unaccounted))
        |> Map.update!(:controlled_lines, &if(line.controlled, do: &1 + 1, else: &1))
      end
    )
  end

  # What the ledger still places at the site; between missions it should be nothing.
  defp still_there(%Mission{} = mission) do
    StockSnapshot
    |> where([s], s.location_id == ^mission.location_id)
    |> select([s], coalesce(sum(s.quantity), 0))
    |> Repo.one()
  end

  @doc """
  Consumption per operating table, the only figure that compares two missions.

  Raw totals say nothing across missions of different size. Returns nil when no
  size was recorded rather than invent a precision.
  """
  def consumption_per_table(%{mission: %Mission{tables: nil}}), do: nil
  def consumption_per_table(%{mission: %Mission{tables: 0}}), do: nil

  def consumption_per_table(%{mission: %Mission{tables: tables}, totals: totals}) do
    totals.consumed |> Decimal.div(tables) |> Decimal.round(2)
  end

  @doc """
  What is still at the mission site and will not survive the trip home.

  Donating at the end of a trip is cheap: the goods are already where they are
  needed, and flying them home to expire helps nobody. FEFO over the stock still
  at the site, using the dashboard's `:expiry_alert_days` window (per-product
  override honoured).

  A suggestion only: nothing is written here; the ordinary write-off flow does it.
  """
  def donation_candidates(%Mission{} = mission) do
    Reports.expiring_soon(location_id: mission.location_id, limit: nil)
  end

  @doc "Mission sites, for the picker on the mission form."
  def list_mission_sites do
    Location
    |> where([l], l.active and l.kind == "mission_site")
    |> order_by([l], asc: l.name)
    |> Repo.all()
  end
end
