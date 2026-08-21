defmodule EstoqueOS.Outbound do
  @moduledoc """
  Stock leaving a place: the load-out ("derrubada de carga") that sends a
  mission's supplies out of the warehouse.

  Two things travel differently. Boxes travel whole — they are picked as
  containers and their presumed contents go with them, no recount. Loose
  stock, the goods that were never boxed, is picked by quantity, and there
  FEFO decides which lot goes: the one expiring first, because what stays
  behind is what will still be good next time.

  Usually the entire stock leaves, so `plan/1` proposes exactly that and the
  screen lets a human take things out of the load rather than add them one by
  one.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  import Ecto.Query
  import EstoqueOS.Coercion

  alias Ecto.Multi
  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Box, Lot, StockSnapshot}
  alias EstoqueOS.Missions
  alias EstoqueOS.Outbound.Shipment
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

  One implementation, in `Locations`, because two screens ask it for opposite
  reasons: the load-out to refuse it, and the box screen to put an end to it.
  """
  defdelegate loose_stock(location_id), to: EstoqueOS.Inventory.Locations

  @doc """
  Sends boxes and loose stock from one location to another.

  Boxes change address and carry their contents. Only boxes travel: stock that is
  not in one cannot be sent, because nothing identifies it at the other end and
  nothing brings it back. A pallet of gauze that leaves loose is, in practice,
  already written off — so the load-out refuses rather than pretending.

  Loose stock at the warehouse is a real and temporary state: goods have arrived
  and nobody has boxed them yet. The receiving conference is where that is
  resolved, and it is the step this refusal sends you back to.

  Everything lands in a single `load_out` transaction so the whole shipment is
  one auditable event, and the boxes' `last_verified_at` is left alone — a
  load-out is not a count.
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

    entries = box_entries(boxes, source_id, destination_id)

    cond do
      picks != [] ->
        {:error, :unboxed_cannot_travel}

      entries == [] ->
        {:error, :nothing_to_send}

      true ->
        Multi.new()
        |> Multi.run(:transaction, fn _repo, _changes ->
          Inventory.post_transaction(%{
            type: "load_out",
            source_location_id: source_id,
            destination_location_id: destination_id,
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
              set: [location_id: destination_id, updated_at: DateTime.utc_now(:second)]
            )

          {:ok, count}
        end)
        |> Multi.run(:shipment, fn _repo, %{transaction: transaction} ->
          # Every load that leaves is a shipment, whether or not anybody was
          # hired to carry it. The alternative — a shipment only when a carrier
          # is named — would leave the volunteer's car trips invisible on the
          # one screen that exists to say what is out there.
          %Shipment{}
          |> Shipment.changeset(%{
            from_location_id: source_id,
            to_location_id: destination_id,
            carrier_id: to_id(field(attrs, :carrier_id)),
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

  ## Shipments

  @doc """
  Loads still out there, the ones that left longest ago first.

  The order is the point: a load that left three weeks ago is the one worth a
  phone call, and "quem está com a carga" is the question this answers.
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

  # How long it has been on the road, and whether it is late. Both derived: a
  # stored "late" would be wrong by tomorrow.
  defp decorate_shipment(%Shipment{} = shipment) do
    today = Date.utc_today()

    %{
      shipment: shipment,
      days_out: Date.diff(today, shipment.shipped_on),
      late?: shipment.expected_arrival != nil and Date.before?(shipment.expected_arrival, today)
    }
  end

  @doc """
  Receives a shipment: the goods arrive, and the load stops being open.

  The movement is the ordinary return — the same lines, the same boxes, the same
  "what did not come back was used" — and this only brackets it. Refused if the
  shipment is already closed, because a load received twice would post its
  contents twice.
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
      # Nothing came back and nothing was written off: the two together say the
      # load evaporated, which is not something to record quietly.
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

  ## Manual issue

  @doc """
  Issues stock by product and quantity, oldest expiry first.

  This is the everyday "someone came and took 30 gauzes" — no invoice, no kit,
  just goods leaving. Per-patient tracking is out of scope, so the destination
  names a place or a purpose, not a person: `Transaction.destinations/0`. It is
  a closed list rather than prose because "what did we donate" has to be a
  query, and a donation carries who received it.
  """
  def issue(product_id, quantity, attrs) do
    issue_many([%{product_id: product_id, quantity: quantity}], attrs)
  end

  @doc """
  Several products leaving together, as one movement.

  Somebody came to the counter and took six things. That is one event, and
  filing it as six makes the log unreadable and the paperwork six times over —
  but more to the point, a basket can be corrected before it is written, and a
  posted transaction cannot: nothing here is ever deleted, so a mistyped line
  becomes a correcting adjustment on the record forever.

  Every line is picked FEFO and the whole thing posts in one transaction, so a
  shortfall on the last line leaves nothing behind from the first.
  """
  def issue_many(lines, attrs) do
    location_id = to_id(field(attrs, :location_id))

    cond do
      is_nil(location_id) -> {:error, :missing_location}
      lines == [] -> {:error, :nothing_to_issue}
      sale_without_price?(lines, attrs) -> {:error, :missing_sale_price}
      true -> do_issue_many(lines, location_id, attrs)
    end
  end

  # A sale is the one destination that carries a number, and it is the number
  # the whole record exists for: "quanto o marketing vendeu" cannot be answered
  # afterwards from a line that never said. Refused rather than posted with a
  # blank, because the goods are gone either way and the price is not
  # recoverable once they are.
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

        case Inventory.suggest_fefo_positions(product_id, quantity,
               location_id: location_id,
               box_id: box_id
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

  # One basket line can become several entries — FEFO splits it across lots —
  # and the price rides on each of them. Per entry rather than per line, because
  # that is the grain the ledger stores and the grain a report has to read: a
  # sale of ten shirts drawn from two lots is two rows, and both were sold at
  # the same price.
  defp entry_for(pick, sale_unit_price) do
    %{
      lot_id: pick.lot_id,
      location_id: pick.location_id,
      box_id: pick.box_id,
      quantity: Decimal.negate(pick.take),
      sale_unit_price: sale_unit_price
    }
  end

  ## Returns

  @doc """
  What the ledger believes is still at a location, position by position, for
  the return conference.

  After a mission this list is a hypothesis, not a fact: things were consumed,
  things moved between boxes, and nobody wrote it down. The screen exists to
  turn it into a fact.
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

  Each line says how much of a position returned and into which box at the
  destination — after a mission things come back in different boxes than they
  left in, so re-boxing is the normal case, not an exception.

  What did not come back is not silently forgotten. With
  `consume_missing: true` the remainder is written off as `manual_out` at the
  mission, which is what actually happened to it; otherwise it stays on the
  mission's books for someone to explain.
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
        # Every line blank. Posting this would consume the mission's whole
        # stock as "used" and call it a return, which is the shape of the
        # accident the blank field made possible in the first place.
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
        # nil and not zero. A blank field means *not counted*, and the two
        # readings are opposites here: zero says the goods did not come back,
        # which with "o que não voltou foi usado" ticked writes the whole line
        # off as consumed. Not counted says nobody has looked yet, and a line
        # nobody looked at must not move.
        quantity: to_decimal(field(line, :quantity)),
        expected: to_decimal(field(line, :expected)) || Decimal.new(0)
      }
    end)
    |> Enum.reject(&is_nil(&1.lot_id))
  end

  # A movement at a mission site belongs to whichever trip was under way there.
  # Nobody is asked to pick: the location and the date already say it, and being
  # asked to name the trip you are standing in is how a field gets left blank.
  # Which trip a movement at this place belongs to. Derived from the location and
  # nothing else — a mission's dates are for a person to read, not a gate the
  # stock consults.
  defp mission_at(location_id) do
    case Missions.for_location(location_id) do
      nil -> nil
      mission -> mission.id
    end
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
end
