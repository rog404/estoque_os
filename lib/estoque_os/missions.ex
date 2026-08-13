defmodule EstoqueOS.Missions do
  @moduledoc """
  Surgical trips, and what each one did to the stock.

  A mission is the unit the coordinator answers for: what left the warehouse,
  what came back, what was used up, and what was handed to the hospital at the
  end. All four are already in the ledger — this context is the lens that groups
  them by trip rather than by day.

  Movements carry `mission_id`, stamped when they happen by the screens that
  know which trip they belong to. Nothing is re-derived at read time: a
  load-out that went to Tefé in March is a fact about that mission, not a guess
  made later from dates that may have shifted.
  """

  import Ecto.Query

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory.{Location, Lot, StockSnapshot, Transaction, TransactionEntry}
  alias EstoqueOS.Missions.Mission
  alias EstoqueOS.Repo

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

  A mission's dates are something for a person to read — when the team flew out,
  when it flew back. They are not a gate the stock consults: a load-out gets
  prepared before the departure date, a box comes home a week after the return
  date because the flight is when the flight is, and a coordinator records both
  whenever they get to a computer. Attributing goods by comparing those dates to
  the clock would file them under nobody on exactly the days that are hardest.

  So the answer comes from the place: the most recent trip to have started there.
  Missions at one place cannot overlap — the database refuses it — so the latest
  is also the open one whenever there is an open one. `nil` for a warehouse,
  which hosts no trips.
  """
  def for_location(nil), do: nil

  def for_location(location_id) do
    Mission
    |> where([m], m.location_id == ^location_id)
    |> order_by([m], desc: m.starts_on, desc: m.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  What the mission did to the stock, product by product.

  Four numbers per line, and they answer different questions:

    * `sent` — what left the warehouse for this trip
    * `returned` — what came back
    * `consumed` — what was used during the mission
    * `donated` — what was handed over at the end, which is not the same as used

  Read at the mission's own location, which is why `sent` counts the arriving
  half of a load-out rather than the leaving half: the question is what the
  mission received, not what the warehouse lost.

  A fifth, `handed_on`, is what left for the next mission without coming home
  first. Stock does not always return between trips, and counting a box that went
  straight to the next city as unaccounted would make the one number that should
  mean something mean nothing.

  `unaccounted` is what is left after all four are subtracted. It is usually zero
  and is worth showing when it is not — the honest name for stock the ledger
  cannot place.
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
    # A load-out at this site is an arrival when it belongs to this mission and a
    # departure when it belongs to the next one.
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

  # What the ledger still believes is sitting at the mission site. Between
  # missions this should be nothing; anything left is either yet to be returned
  # or has quietly stayed behind.
  defp still_there(%Mission{} = mission) do
    StockSnapshot
    |> where([s], s.location_id == ^mission.location_id)
    |> select([s], coalesce(sum(s.quantity), 0))
    |> Repo.one()
  end

  @doc """
  Consumption per operating table, the only figure that compares two missions.

  A mission of six tables uses more than one of four, so the raw total says
  nothing about whether a trip went through more than it should have. Returns
  nil when nobody recorded the size — a division by a number nobody entered
  would be an invented precision.
  """
  def consumption_per_table(%{mission: %Mission{tables: nil}}), do: nil
  def consumption_per_table(%{mission: %Mission{tables: 0}}), do: nil

  def consumption_per_table(%{mission: %Mission{tables: tables}, totals: totals}) do
    totals.consumed |> Decimal.div(tables) |> Decimal.round(2)
  end

  @doc "Mission sites, for the picker on the mission form."
  def list_mission_sites do
    Location
    |> where([l], l.active and l.kind == "mission_site")
    |> order_by([l], asc: l.name)
    |> Repo.all()
  end
end
