defmodule EstoqueOSWeb.ReturnLive.Index do
  @moduledoc """
  Receiving a mission back.

  The list starts from what the ledger believes is still out there, which
  after a mission is a hypothesis. Each line asks two questions: how much
  actually came back, and into which box here — because things return in
  different boxes than they left in, and that is normal.
  """

  use EstoqueOSWeb, :live_view

  import EstoqueOS.Coercion

  alias EstoqueOS.Outbound

  alias EstoqueOS.Inventory.Locations

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Choosing the route reloads the list of what is still out there. `receive`
  is the movement, and `confirm_new_box` creates a box.
  """
  def viewer_events, do: ~w(route cancel_new_box)

  @impl true
  def mount(_params, _session, socket) do
    locations = Locations.list_locations()
    source = Enum.find(locations, &(&1.kind == "mission_site")) || List.first(locations)
    destination = Locations.default_location() || List.first(locations)

    {:ok,
     socket
     |> assign(:page_title, gettext("Mission return"))
     |> assign(:locations, locations)
     |> assign(:source_id, source && source.id)
     |> assign(:destination_id, destination && destination.id)
     |> assign(:new_boxes, nil)
     |> load_plan()}
  end

  defp load_plan(socket) do
    lines =
      if socket.assigns.source_id, do: Outbound.plan_return(socket.assigns.source_id), else: []

    boxes =
      if socket.assigns.destination_id,
        do: Locations.list_boxes(socket.assigns.destination_id),
        else: []

    socket
    |> assign(:lines, lines)
    |> assign(:boxes, boxes)
    |> assign(:suggestions, suggestions_for(lines, socket.assigns.destination_id))
  end

  # Computed once for the whole return rather than per line as it renders: a
  # mission comes home as dozens of lines and the warehouse's contents do not
  # change between two of them.
  defp suggestions_for(_lines, nil), do: %{}

  defp suggestions_for(lines, destination_id) do
    lines
    |> Enum.map(& &1.product_id)
    |> Enum.uniq()
    |> Map.new(&{&1, Locations.suggest_boxes(&1, destination_id, limit: 1)})
  end

  # Every line used to land on "sem caixa", so somebody re-picked a box for each
  # of forty rows after every mission. Two things can answer it without being
  # asked: the box the goods left in, when that box is already home, and the box
  # at the warehouse that holds this product anyway.
  #
  # A suggestion, never a decision — things do come back in different boxes than
  # they left in, which is the premise of this screen.
  defp default_box_code(line, boxes, suggestions) do
    if came_home?(line, boxes) do
      line.box_code
    else
      suggested_box_code(suggestions[line.product_id])
    end
  end

  defp box_reason(line, boxes, suggestions) do
    if came_home?(line, boxes) do
      gettext("came back in this one")
    else
      case suggestions[line.product_id] do
        [suggestion | _rest] -> suggestion_reason(suggestion)
        _none -> nil
      end
    end
  end

  # The box the goods left in, already back at the destination — either it
  # travelled home ahead of them or it never left.
  defp came_home?(%{box_id: nil}, _boxes), do: false
  defp came_home?(line, boxes), do: Enum.any?(boxes, &(&1.id == line.box_id))

  defp suggested_box_code([%{box: box} | _rest]), do: box.code
  defp suggested_box_code(_none), do: nil

  defp suggestion_reason(%{reason: :same_product, because: name}) do
    gettext("already holds %{product}", product: name)
  end

  defp suggestion_reason(%{reason: :same_group, because: name}) do
    gettext("holds %{product}, from the same group", product: name)
  end

  defp suggestion_reason(%{reason: :same_sector, because: sector}) do
    gettext("holds %{sector} items", sector: sector)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Mission return")}
        <:subtitle>
          {gettext("Count what came back and say which box it went into.")}
        </:subtitle>
      </.header>

      <form id="route-form" phx-change="route" class="field-row mt-4">
        <label class="fieldset">
          <span class="label">{gettext("Coming from")}</span>
          <select name="source_id" class="select select-bordered">
            <option
              :for={location <- @locations}
              value={location.id}
              selected={location.id == @source_id}
            >
              {location.name}
            </option>
          </select>
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Arriving at")}</span>
          <select name="destination_id" class="select select-bordered">
            <option
              :for={location <- @locations}
              value={location.id}
              selected={location.id == @destination_id}
              disabled={location.id == @source_id}
            >
              {location.name}
            </option>
          </select>
        </label>
      </form>

      <p :if={@lines == []} class="mt-8 opacity-70">
        {gettext("The ledger says there is nothing out there.")}
      </p>

      <.box_options id="return-boxes" boxes={@boxes} />

      <form :if={@lines != []} id="return-form" phx-submit="receive" class="mt-6">
        <.panel title={gettext("Boxes coming back")} flush>
          <.data_table
            rows={Enum.with_index(@lines)}
            row_id={fn {_line, index} -> "line-#{index}" end}
          >
            <:col :let={{line, _index}} label={gettext("Product")} emphasis={:identity}>
              {line.product}
              <.status :if={line.controlled} kind={:controlled} />
            </:col>
            <:col :let={{line, _index}} label={gettext("Lot")}>
              {line.lot_number || gettext("unknown")}
              <span :if={line.expires_on} class="text-xs opacity-60">
                · {date(line.expires_on)}
              </span>
            </:col>
            <:col :let={{line, _index}} label={gettext("Left in")}>
              {line.box_code || "—"}
            </:col>
            <:col :let={{line, _index}} label={gettext("Ledger says")} align={:right}>
              {quantity(line.expected)}
            </:col>
            <:col :let={{line, index}} label={gettext("Came back")} align={:right} field={:inline}>
              <input type="hidden" name={"lines[#{index}][lot_id]"} value={line.lot_id} />
              <input type="hidden" name={"lines[#{index}][from_box_id]"} value={line.box_id} />
              <input
                type="hidden"
                name={"lines[#{index}][expected]"}
                value={quantity(line.expected)}
              />
              <input
                type="text"
                name={"lines[#{index}][quantity]"}
                value={quantity(line.expected)}
                inputmode="decimal"
                data-numeric
                class="input input-sm input-bordered w-24 text-right"
                aria-label={gettext("Quantity that came back")}
              />
            </:col>
            <:col :let={{line, index}} label={gettext("Into box")} field={:block}>
              <.box_picker
                name={"lines[#{index}][to_box_code]"}
                boxes={@boxes}
                list_id="return-boxes"
                value={default_box_code(line, @boxes, @suggestions)}
                label={gettext("Box it came back into")}
                hint={box_reason(line, @boxes, @suggestions)}
              />
            </:col>
          </.data_table>
        </.panel>

        <.check
          name="consume_missing"
          label={gettext("What did not come back was used during the mission")}
          checked
          class="mt-4"
        />

        <.new_box_confirm :if={@new_boxes} codes={@new_boxes.codes} class="mt-4" />

        <div class="flex flex-wrap items-center gap-4 border-t border-base-300 pt-4 mt-4">
          <.commit_action
            id="confirm-return"
            form="return-form"
            label={gettext("Receive return")}
            title={gettext("Receive this return?")}
          >
            <:consequence>
              <p>
                {gettext("%{count} position(s) come back to %{to}.",
                  count: length(@lines),
                  to: location_name(@locations, @destination_id)
                )}
              </p>
              <p class="text-sm text-warning">
                {gettext(
                  "Whatever did not come back is written off as used during the mission, unless you unchecked that."
                )}
              </p>
            </:consequence>
          </.commit_action>
          <p class="text-sm opacity-70">
            {gettext("Unchecked, the missing goods stay on the mission's books.")}
          </p>
        </div>
      </form>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("route", params, socket) do
    {:noreply,
     socket
     |> assign(:source_id, to_id(params["source_id"]))
     |> assign(:destination_id, to_id(params["destination_id"]))
     |> load_plan()}
  end

  def handle_event("receive", params, socket) do
    do_receive(socket, params, create: false)
  end

  # The yes. Nothing was written while the question was open, so this replays
  # the same submission with permission to create.
  def handle_event("confirm_new_box", _params, socket) do
    %{params: params} = socket.assigns.new_boxes

    socket
    |> assign(:new_boxes, nil)
    |> do_receive(params, create: true)
  end

  def handle_event("cancel_new_box", _params, socket) do
    {:noreply, assign(socket, :new_boxes, nil)}
  end

  defp do_receive(socket, params, opts) do
    {lines, created, unknown} =
      params
      |> Map.get("lines", %{})
      |> resolve_line_boxes(socket.assigns.destination_id, opts)

    if unknown != [] do
      throw_unknown(socket, params, unknown)
    else
      write_return(socket, params, lines, created)
    end
  end

  defp throw_unknown(socket, params, unknown) do
    {:noreply, assign(socket, :new_boxes, %{codes: unknown, params: params})}
  end

  defp write_return(socket, params, lines, created) do
    attrs = %{
      source_location_id: socket.assigns.source_id,
      destination_location_id: socket.assigns.destination_id,
      lines: lines,
      consume_missing: params["consume_missing"],
      user_id: socket.assigns.current_scope.user.id
    }

    case Outbound.receive_return(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, result_message(result, created))
         |> load_plan()}

      {:error, {:negative_stock, _positions}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Some line says more came back than went out. Check the quantities.")
         )}

      {:error, :nothing_returned} ->
        {:noreply, put_flash(socket, :error, gettext("Nothing to receive."))}

      {:error, :same_location} ->
        {:noreply,
         put_flash(socket, :error, gettext("Choose a destination other than the origin."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The return could not be recorded."))}
    end
  end

  # Forty lines can name the same new box, and can name several. Each code is
  # resolved once, and every box the return brought into existence is said out
  # loud — a typo in a code is a box nobody meant to create, and the only cheap
  # moment to notice is now.
  defp resolve_line_boxes(lines, destination_id, opts) do
    {resolved, {created, unknown}} =
      Enum.map_reduce(lines, {[], []}, fn {index, line}, {created, unknown} ->
        case Locations.resolve_box(line["to_box_code"], destination_id, opts) do
          {:ok, box} ->
            {{index, box_id(line, box)}, {created, unknown}}

          {:created, box} ->
            {{index, box_id(line, box)}, {[box.code | created], unknown}}

          # Held, not written. Every code the form invented is collected so the
          # operator is asked about all of them at once — asking three times in
          # a row is how the third one gets waved through.
          {:unknown, code} ->
            {{index, Map.put(line, "to_box_id", nil)}, {created, [code | unknown]}}

          {:error, _reason} ->
            {{index, Map.put(line, "to_box_id", nil)}, {created, unknown}}
        end
      end)

    {Map.new(resolved), tidy(created), tidy(unknown)}
  end

  defp tidy(codes), do: codes |> Enum.uniq() |> Enum.reverse()

  defp box_id(line, box), do: Map.put(line, "to_box_id", box && box.id)

  defp result_message(result, created) do
    [base_message(result), created_message(created)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp base_message(%{consumed: nil}), do: gettext("Return received.")

  defp base_message(_result),
    do: gettext("Return received; what did not come back was written off as used.")

  defp created_message([]), do: nil

  defp created_message(codes),
    do: gettext("New box(es) created here: %{codes}", codes: Enum.join(codes, ", "))

  defp location_name(locations, id) do
    case Enum.find(locations, &(&1.id == id)) do
      nil -> "—"
      location -> location.name
    end
  end
end
