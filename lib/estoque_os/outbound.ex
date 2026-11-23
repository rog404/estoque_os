defmodule EstoqueOS.Outbound do
  @moduledoc """
  Stock leaving a place: the load-out ("derrubada de carga") that sends a
  mission's supplies out of the warehouse.

  Boxes travel whole, with presumed contents and no recount. Loose stock is
  picked by quantity under FEFO (what stays behind will still be good next time).

  Usually everything leaves, so `plan/1` proposes everything and a human
  removes lines rather than adding them.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Box, Locations, Lot, StockSnapshot, TransactionEntry}
  alias EstoqueOS.Missions
  alias EstoqueOS.Outbound.{Shipment, TransportDeclaration}
  alias EstoqueOS.Repo

  @doc """
  What is available to leave a location: boxes as whole containers, and the
  loose stock that is in no box.
  """
  def plan(location_id) do
    %{boxes: boxes_at(location_id), loose: loose_stock(location_id)}
  end

  defp boxes_at(location_id) do
    quantities =
      StockSnapshot
      |> where([s], s.location_id == ^location_id and not is_nil(s.box_id) and s.quantity != 0)
      |> group_by([s], s.box_id)
      |> select([s], {s.box_id, %{quantity: sum(s.quantity), positions: count(s.id)}})
      |> Repo.all()
      |> Map.new()

    Box
    |> where([b], b.location_id == ^location_id and b.active and b.id in ^Map.keys(quantities))
    |> order_by([b], asc: b.code)
    |> Repo.all()
    |> Enum.map(&Map.merge(%{box: &1}, Map.fetch!(quantities, &1.id)))
  end

  @doc """
  Stock at a location that is in no box, per lot, FEFO first.

  One implementation, in `Locations`: the load-out uses it to refuse, the box
  screen to resolve it.
  """
  defdelegate loose_stock(location_id), to: EstoqueOS.Inventory.Locations

  @doc """
  Sends boxes and loose stock from one location to another.

  Boxes change address and carry their contents. Only boxes travel: loose stock
  has nothing identifying it at the other end and nothing bringing it back, so
  the load-out refuses it (the receiving conference is where it gets boxed).

  One `load_out` transaction makes the shipment a single auditable event;
  `last_verified_at` is left alone, a load-out is not a count.
  """
  def load_out(attrs) do
    source_id = to_id(field(attrs, :source_location_id))
    destination_id = to_id(field(attrs, :destination_location_id))
    box_ids = Enum.map(field(attrs, :box_ids) || [], &to_id/1)
    picks = normalize_picks(field(attrs, :picks) || [])

    cond do
      is_nil(source_id) or is_nil(destination_id) ->
        {:error, :missing_location}

      source_id == destination_id ->
        {:error, :same_location}

      box_ids == [] and picks == [] ->
        {:error, :nothing_to_send}

      true ->
        do_load_out(source_id, destination_id, box_ids, picks, attrs)
    end
  end

  defp do_load_out(source_id, destination_id, box_ids, picks, attrs) do
    boxes = Repo.all(from b in Box, where: b.id in ^box_ids)
    carrier_id = to_id(field(attrs, :carrier_id))

    # With a carrier the goods rest in transit, not at the mission: otherwise
    # the mission would pick against stock still on the highway. Driven by the
    # ONG, they go straight there. The shipment keeps the destination either way.
    resting_id = resting_location(carrier_id, destination_id)

    entries = box_entries(boxes, source_id, resting_id)

    cond do
      picks != [] ->
        {:error, :unboxed_cannot_travel}

      entries == [] ->
        {:error, :nothing_to_send}

      is_nil(resting_id) ->
        {:error, :no_transit_location}

      true ->
        Multi.new()
        |> Multi.run(:transaction, fn _repo, _changes ->
          Inventory.post_transaction(%{
            type: "load_out",
            source_location_id: source_id,
            destination_location_id: resting_id,
            mission_id: mission_at(destination_id),
            source_mission_id: mission_at(source_id),
            user_id: field(attrs, :user_id),
            notes: field(attrs, :notes),
            entries: entries
          })
        end)
        |> Multi.run(:boxes, fn repo, _changes ->
          {count, _} =
            Box
            |> where([b], b.id in ^box_ids)
            |> repo.update_all(
              set: [location_id: resting_id, updated_at: DateTime.utc_now(:second)]
            )

          {:ok, count}
        end)
        |> Multi.run(:shipment, fn _repo, %{transaction: transaction} ->
          # Every load is a shipment, carrier or not, so volunteer car trips
          # show on the screen that says what is out there.
          %Shipment{}
          |> Shipment.changeset(%{
            from_location_id: source_id,
            to_location_id: destination_id,
            carrier_id: carrier_id,
            waybill: blank_to_nil(field(attrs, :waybill)),
            expected_arrival: field(attrs, :expected_arrival),
            mission_id: mission_at(destination_id),
            notes: field(attrs, :notes),
            sent_transaction_id: transaction.id
          })
          |> Repo.insert()
        end)
        |> Repo.transaction()
        |> case do
          {:ok, changes} ->
            {:ok,
             %{
               transaction: changes.transaction,
               boxes_moved: changes.boxes,
               shipment: changes.shipment
             }}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  defp resting_location(nil, destination_id), do: destination_id

  defp resting_location(_carrier_id, destination_id) do
    case Locations.transit_location() do
      nil -> nil
      %{id: id} when id == destination_id -> destination_id
      transit -> transit.id
    end
  end

  @doc """
  Loads still out there, longest ago first: the oldest is the one worth a phone call.
  """
  def open_shipments(opts \\ []) do
    Shipment
    |> where([s], is_nil(s.received_at))
    |> order_by([s], asc: s.shipped_on, asc: s.id)
    |> maybe_carrier(opts[:carrier_id])
    |> preload([:carrier, :from_location, :to_location, :mission])
    |> Repo.all()
    |> Enum.map(&decorate_shipment/1)
  end

  defp maybe_carrier(query, nil), do: query
  defp maybe_carrier(query, id), do: where(query, [s], s.carrier_id == ^id)

  # Derived, not stored: a stored "late" would be wrong by tomorrow.
  defp decorate_shipment(%Shipment{} = shipment) do
    today = Date.utc_today()

    %{
      shipment: shipment,
      days_out: Date.diff(today, shipment.shipped_on),
      in_transit?: Shipment.in_transit?(shipment),
      late?: shipment.expected_arrival != nil and Date.before?(shipment.expected_arrival, today)
    }
  end

  @doc """
  Loads on the road right now: a carrier has them and nobody has said they
  landed.
  """
  def shipments_in_transit(opts \\ []) do
    Shipment
    |> where([s], is_nil(s.arrived_at) and not is_nil(s.carrier_id))
    |> order_by([s], asc: s.shipped_on, asc: s.id)
    |> maybe_carrier(opts[:carrier_id])
    |> preload([:carrier, :from_location, :to_location, :mission])
    |> Repo.all()
    |> Enum.map(&decorate_shipment/1)
  end

  @doc "One shipment, with everything the screens name."
  def get_shipment!(id) do
    Shipment
    |> Repo.get!(id)
    |> Repo.preload([:carrier, :from_location, :to_location, :mission])
  end

  @doc """
  The load landed: whatever is in transit for this shipment finishes the trip.

  The last leg, an ordinary transfer of every box the load-out put in transit
  to the shipment's destination. Nothing is counted; that happens when somebody
  opens the boxes.

  Refused for a load with no carrier (it never stopped at transit) and for one
  already stamped (it would move the same goods twice).
  """
  def arrive_shipment(%Shipment{} = shipment, attrs \\ %{}) do
    if Shipment.in_transit?(shipment) do
      do_arrive(shipment, attrs)
    else
      {:error, :not_in_transit}
    end
  end

  defp do_arrive(shipment, attrs) do
    entries = transit_entries(shipment)

    if entries == [] do
      {:error, :nothing_in_transit}
    else
      Multi.new()
      |> Multi.run(:transaction, fn _repo, _changes ->
        Inventory.post_transaction(%{
          type: "transfer",
          source_location_id: shipment.from_location_id,
          destination_location_id: shipment.to_location_id,
          mission_id: shipment.mission_id,
          user_id: field(attrs, :user_id),
          notes: field(attrs, :notes) || arrival_note(shipment),
          entries: entries
        })
      end)
      |> Multi.run(:boxes, fn repo, _changes ->
        box_ids = entries |> Enum.map(& &1.box_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        {count, _} =
          Box
          |> where([b], b.id in ^box_ids)
          |> repo.update_all(
            set: [location_id: shipment.to_location_id, updated_at: DateTime.utc_now(:second)]
          )

        {:ok, count}
      end)
      |> Multi.run(:shipment, fn repo, %{transaction: transaction} ->
        shipment
        |> Shipment.arrival_changeset(%{
          arrived_at: DateTime.utc_now(:second),
          arrival_transaction_id: transaction.id
        })
        |> repo.update()
      end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} ->
          {:ok, %{shipment: changes.shipment, transaction: changes.transaction}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp arrival_note(shipment) do
    gettext("arrived at %{place}", place: shipment.to_location.name)
  end

  # Boxes only: loose stock cannot travel.
  defp transit_entries(shipment) do
    case Locations.transit_location() do
      nil ->
        []

      transit ->
        box_ids = shipment_box_ids(shipment)

        StockSnapshot
        |> where([s], s.location_id == ^transit.id and s.quantity != 0)
        |> where([s], s.box_id in ^box_ids)
        |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
        |> Repo.all()
        |> Enum.flat_map(fn row ->
          [
            %{
              lot_id: row.lot_id,
              box_id: row.box_id,
              location_id: transit.id,
              quantity: Decimal.negate(row.quantity)
            },
            %{
              lot_id: row.lot_id,
              box_id: row.box_id,
              location_id: shipment.to_location_id,
              quantity: row.quantity
            }
          ]
        end)
    end
  end

  # The boxes this load took out, read from the movement that sent it.
  defp shipment_box_ids(shipment) do
    TransactionEntry
    |> where([e], e.transaction_id == ^shipment.sent_transaction_id)
    |> select([e], e.box_id)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  What a load is carrying, as the declaration prints it.

  Read from the movement that sent it: the paper must say what actually left.
  The positive side of the load-out names the goods; the negative is the same
  goods leaving the warehouse.
  """
  def shipment_contents(%Shipment{} = shipment) do
    costs = Inventory.average_unit_costs()

    TransactionEntry
    |> join(:inner, [e], l in Lot, on: l.id == e.lot_id)
    |> join(:inner, [e, l], p in Product, on: p.id == l.product_id)
    |> join(:left, [e, l, p], b in Box, on: b.id == e.box_id)
    |> where([e], e.transaction_id == ^shipment.sent_transaction_id)
    |> where([e], e.quantity > 0)
    # By box, then product: the checker is holding the boxes.
    |> order_by([e, l, p, b], asc: b.code, asc: p.name, asc: l.lot_number)
    |> select([e, l, p, b], %{
      product: p.name,
      unit: p.stock_unit,
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      box: b.code,
      quantity: e.quantity
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      cost = costs[row.lot_id]

      row
      |> Map.put(:unit_cost, cost)
      |> Map.put(:total, cost && Decimal.mult(cost, row.quantity))
    end)
  end

  @doc """
  What the load is worth, for the line the carrier's paperwork asks for.

  Only the part whose cost is known: a donated lot has none, and zero would
  misdeclare the value. `unvalued` counts those lines.
  """
  def contents_total(rows) do
    %{
      quantity: sum_by(rows, & &1.quantity),
      value: rows |> Enum.map(& &1.total) |> Enum.reject(&is_nil/1) |> sum(),
      unvalued: Enum.count(rows, &is_nil(&1.total))
    }
  end

  defp sum_by(rows, fun), do: rows |> Enum.map(fun) |> sum()
  defp sum(values), do: Enum.reduce(values, Decimal.new(0), &Decimal.add/2)

  @doc "The declaration written for this load, if somebody wrote one."
  def get_declaration(%Shipment{} = shipment) do
    Repo.get_by(TransportDeclaration, shipment_id: shipment.id)
  end

  @doc """
  Writes the declaration for a load, or rewrites the one already there.

  One paper per load: a second declaration could disagree about what travelled.
  """
  def save_declaration(%Shipment{} = shipment, attrs) do
    (get_declaration(shipment) || %TransportDeclaration{})
    |> TransportDeclaration.changeset(Map.put(attrs, :shipment_id, shipment.id))
    |> Repo.insert_or_update()
  end

  @doc "An empty declaration with what the load already knows filled in."
  def declaration_draft(%Shipment{} = shipment) do
    %TransportDeclaration{
      shipment_id: shipment.id,
      recipient_name: shipment.to_location && shipment.to_location.name,
      issued_on: shipment.shipped_on || Date.utc_today(),
      reference: reference_for(shipment)
    }
  end

  # "2026/04": year and month the load left, how the ONG numbers these.
  defp reference_for(%Shipment{shipped_on: nil}), do: nil

  defp reference_for(%Shipment{shipped_on: date}) do
    "#{date.year}/#{String.pad_leading(to_string(date.month), 2, "0")}"
  end

  @doc """
  Receives a shipment: the goods arrive, and the load stops being open.

  The movement is the ordinary return; this only brackets it. Refused if already
  closed, as receiving twice would post the contents twice.
  """
  def receive_shipment(%Shipment{} = shipment, attrs) do
    if Shipment.open?(shipment) do
      attrs =
        attrs
        |> Map.put(:source_location_id, shipment.to_location_id)
        |> Map.put_new(:destination_location_id, shipment.from_location_id)

      case receive_return(attrs) do
        {:ok, result} -> close_shipment(shipment, result, attrs)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :already_received}
    end
  end

  defp close_shipment(shipment, result, attrs) do
    transaction = result[:return] || result[:consumed]

    if is_nil(transaction) do
      # Nothing back and nothing written off means the load evaporated; not recorded quietly.
      {:error, :nothing_received}
    else
      do_close_shipment(shipment, transaction, result, attrs)
    end
  end

  defp do_close_shipment(shipment, transaction, result, attrs) do
    shipment
    |> Shipment.receipt_changeset(%{
      received_at: DateTime.utc_now(:second),
      received_by_id: field(attrs, :user_id),
      received_transaction_id: transaction.id
    })
    |> Repo.update()
    |> case do
      {:ok, shipment} -> {:ok, Map.put(result, :shipment, shipment)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp box_entries([], _source_id, _destination_id), do: []

  defp box_entries(boxes, source_id, destination_id) do
    box_ids = Enum.map(boxes, & &1.id)

    StockSnapshot
    |> where([s], s.box_id in ^box_ids and s.location_id == ^source_id and s.quantity != 0)
    |> select([s], %{lot_id: s.lot_id, box_id: s.box_id, quantity: s.quantity})
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      [
        %{
          lot_id: row.lot_id,
          box_id: row.box_id,
          location_id: source_id,
          quantity: Decimal.negate(row.quantity)
        },
        %{
          lot_id: row.lot_id,
          box_id: row.box_id,
          location_id: destination_id,
          quantity: row.quantity
        }
      ]
    end)
  end

  defp normalize_picks(picks) when is_map(picks) do
    picks
    |> Enum.map(fn {lot_id, quantity} ->
      %{lot_id: to_id(lot_id), quantity: to_decimal(quantity)}
    end)
    |> Enum.reject(&(is_nil(&1.quantity) or Decimal.compare(&1.quantity, 0) != :gt))
  end

  defp normalize_picks(picks) when is_list(picks) do
    picks
    |> Enum.map(fn pick ->
      %{
        lot_id: to_id(field(pick, :lot_id)),
        quantity: to_decimal(field(pick, :quantity))
      }
    end)
    |> Enum.reject(&(is_nil(&1.quantity) or Decimal.compare(&1.quantity, 0) != :gt))
  end

  @doc """
  Issues stock by product and quantity, FEFO: the everyday "someone took 30
  gauzes". Per-patient tracking is out of scope, so the destination names a
  place or purpose (`Transaction.destinations/0`), a closed list so "what did we
  donate" is a query; a donation carries who received it.
  """
  def issue(product_id, quantity, attrs) do
    issue_many([%{product_id: product_id, quantity: quantity}], attrs)
  end

  @doc """
  Several products leaving together, as one movement.

  One event, not several: a basket can be corrected before posting, while a
  posted transaction never can (a mistyped line would be a correcting
  adjustment forever).

  Every line is picked FEFO and all post in one transaction, so a shortfall on
  the last line leaves nothing from the first.
  """
  def issue_many(lines, attrs) do
    location_id = to_id(field(attrs, :location_id))

    cond do
      is_nil(location_id) -> {:error, :missing_location}
      lines == [] -> {:error, :nothing_to_issue}
      is_nil(blank_to_nil(field(attrs, :destination))) -> {:error, :missing_destination}
      sale_without_price?(lines, attrs) -> {:error, :missing_sale_price}
      true -> do_issue_many(lines, location_id, attrs)
    end
  end

  # A blank destination cannot be filled in afterwards, so it is refused here
  # (a form `required` is presentation, this is a rule). A sale must carry its
  # price for the same reason: "quanto o marketing vendeu" is unrecoverable once
  # the goods are gone.
  defp sale_without_price?(lines, attrs) do
    field(attrs, :destination) == "sale" and
      Enum.any?(lines, &is_nil(to_decimal(field(&1, :sale_unit_price))))
  end

  defp do_issue_many(lines, location_id, attrs) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, entries} ->
      quantity = to_decimal(field(line, :quantity))
      product_id = to_id(field(line, :product_id))

      if is_nil(quantity) or Decimal.compare(quantity, 0) != :gt do
        {:halt, {:error, :invalid_quantity}}
      else
        box_id = to_id(field(line, :box_id))
        lot_id = to_id(field(line, :lot_id))

        case Inventory.suggest_fefo_positions(product_id, quantity,
               location_id: location_id,
               box_id: box_id,
               lot_id: lot_id
             ) do
          {:insufficient_stock, _picks, missing} ->
            {:halt, {:error, {:insufficient_stock, %{missing: missing, item: product_id}}}}

          {:ok, picks} ->
            price = to_decimal(field(line, :sale_unit_price))

            {:cont, {:ok, entries ++ Enum.map(picks, &entry_for(&1, price))}}
        end
      end
    end)
    |> case do
      {:ok, entries} ->
        Inventory.post_transaction(%{
          type: "manual_out",
          source_location_id: location_id,
          mission_id: mission_at(location_id),
          user_id: field(attrs, :user_id),
          destination: field(attrs, :destination),
          recipient_name: field(attrs, :recipient_name),
          recipient_tax_id: field(attrs, :recipient_tax_id),
          notes: field(attrs, :notes),
          entries: entries
        })

      error ->
        error
    end
  end

  # FEFO can split one line across lots; the price rides on each entry, the
  # grain the ledger stores and reports read.
  defp entry_for(pick, sale_unit_price) do
    %{
      lot_id: pick.lot_id,
      location_id: pick.location_id,
      box_id: pick.box_id,
      quantity: Decimal.negate(pick.take),
      sale_unit_price: sale_unit_price
    }
  end

  @doc """
  What the ledger believes is still at a location, position by position, for
  the return conference. After a mission it is a hypothesis the screen turns
  into a fact.
  """
  def plan_return(location_id) do
    StockSnapshot
    |> join(:inner, [s], l in Lot, on: l.id == s.lot_id)
    |> join(:inner, [s, l], p in Product, on: p.id == l.product_id)
    |> join(:left, [s], b in Box, on: b.id == s.box_id)
    |> where([s], s.location_id == ^location_id and s.quantity != 0)
    |> order_by([s, l, p], asc: p.name, asc_nulls_last: l.expires_on)
    |> select([s, l, p, b], %{
      lot_id: l.id,
      lot_number: l.lot_number,
      expires_on: l.expires_on,
      product_id: p.id,
      product: p.name,
      controlled: p.controlled,
      box_id: s.box_id,
      box_code: b.code,
      expected: s.quantity
    })
    |> Repo.all()
  end

  @doc """
  Receives a return from a mission, counting what actually came back.

  Each line says how much of a position returned and into which destination
  box; things come back in different boxes, so re-boxing is normal.

  What did not come back is not forgotten: with `consume_missing: true` the
  remainder is written off as `manual_out` at the mission; otherwise it stays
  on the mission's books for someone to explain.
  """
  def receive_return(attrs) do
    source_id = to_id(field(attrs, :source_location_id))
    destination_id = to_id(field(attrs, :destination_location_id))
    lines = normalize_return_lines(field(attrs, :lines) || [])
    consume_missing? = truthy?(field(attrs, :consume_missing))

    cond do
      is_nil(source_id) or is_nil(destination_id) ->
        {:error, :missing_location}

      source_id == destination_id ->
        {:error, :same_location}

      lines == [] ->
        {:error, :nothing_returned}

      Enum.all?(lines, &is_nil(&1.quantity)) ->
        # All blank: posting would consume the mission's whole stock as "used".
        {:error, :nothing_counted}

      true ->
        do_receive_return(source_id, destination_id, lines, consume_missing?, attrs)
    end
  end

  defp do_receive_return(source_id, destination_id, lines, consume_missing?, attrs) do
    user_id = field(attrs, :user_id)

    counted = Enum.reject(lines, &is_nil(&1.quantity))

    returned =
      Enum.flat_map(counted, fn line ->
        if Decimal.compare(line.quantity, 0) == :gt do
          [
            %{
              lot_id: line.lot_id,
              location_id: source_id,
              box_id: line.from_box_id,
              quantity: Decimal.negate(line.quantity)
            },
            %{
              lot_id: line.lot_id,
              location_id: destination_id,
              box_id: line.to_box_id,
              quantity: line.quantity
            }
          ]
        else
          []
        end
      end)

    missing =
      if consume_missing? do
        Enum.flat_map(counted, fn line ->
          left_behind = Decimal.sub(line.expected, line.quantity)

          if Decimal.compare(left_behind, 0) == :gt do
            [
              %{
                lot_id: line.lot_id,
                location_id: source_id,
                box_id: line.from_box_id,
                quantity: Decimal.negate(left_behind)
              }
            ]
          else
            []
          end
        end)
      else
        []
      end

    Multi.new()
    |> maybe_post(:return, returned, %{
      type: "return_in",
      source_location_id: source_id,
      destination_location_id: destination_id,
      mission_id: mission_at(source_id),
      user_id: user_id,
      notes: field(attrs, :notes)
    })
    |> maybe_post(:consumed, missing, %{
      type: "manual_out",
      source_location_id: source_id,
      mission_id: mission_at(source_id),
      user_id: user_id,
      notes: gettext("Used during the mission (did not come back)")
    })
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        {:ok, %{return: changes[:return], consumed: changes[:consumed]}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp maybe_post(multi, _name, [], _attrs), do: multi

  defp maybe_post(multi, name, entries, attrs) do
    Multi.run(multi, name, fn _repo, _changes ->
      Inventory.post_transaction(Map.put(attrs, :entries, entries))
    end)
  end

  defp normalize_return_lines(lines) when is_map(lines) do
    lines |> Map.values() |> normalize_return_lines()
  end

  defp normalize_return_lines(lines) when is_list(lines) do
    lines
    |> Enum.map(fn line ->
      %{
        lot_id: to_id(field(line, :lot_id)),
        from_box_id: to_id(field(line, :from_box_id)),
        to_box_id: to_id(field(line, :to_box_id)),
        # nil, not zero: blank means *not counted* and must not move, while zero
        # means "did not come back" and, with "o que não voltou foi usado"
        # ticked, writes the line off as consumed.
        quantity: to_decimal(field(line, :quantity)),
        expected: to_decimal(field(line, :expected)) || Decimal.new(0)
      }
    end)
    |> Enum.reject(&is_nil(&1.lot_id))
  end

  # Which trip a movement at this place belongs to, derived from the location
  # alone so nobody is asked to name it.
  defp mission_at(location_id) do
    case Missions.for_location(location_id) do
      nil -> nil
      mission -> mission.id
    end
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
end
