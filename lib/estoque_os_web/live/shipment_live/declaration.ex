defmodule EstoqueOSWeb.ShipmentLive.Declaration do
  @moduledoc """
  The declaração de conteúdo for one load, before it is printed.

  What the system knows is filled in — the goods, the date, the reference, where
  the load is going. What only the person sending it knows is typed: the
  hospital's registration and address, the carrier's scheduling code, the
  invoice that covers the goods.

  It is saved rather than thrown away after printing, so the second copy the
  carrier asks for on Monday is the same paper and not a new act of typing.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Outbound
  alias EstoqueOS.Outbound.TransportDeclaration

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  `save` writes the paper.
  """
  def viewer_events, do: ~w()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    shipment = Outbound.get_shipment!(id)
    declaration = Outbound.get_declaration(shipment) || Outbound.declaration_draft(shipment)
    contents = Outbound.shipment_contents(shipment)

    {:ok,
     socket
     |> assign(:page_title, gettext("Content declaration"))
     |> assign(:shipment, shipment)
     |> assign(:saved?, declaration.id != nil)
     |> assign(:contents, contents)
     |> assign(:totals, Outbound.contents_total(contents))
     |> assign(:form, to_form(TransportDeclaration.changeset(declaration, %{})))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header back_to={~p"/reports/transit"} back_label={gettext("In transit")}>
        {gettext("Content declaration")}
        <:subtitle>
          {gettext("%{from} to %{to}, left on %{date}",
            from: @shipment.from_location.name,
            to: @shipment.to_location.name,
            date: date(@shipment.shipped_on)
          )}
        </:subtitle>
      </.header>

      <.form for={@form} id="declaration-form" phx-submit="save" class="mt-4 space-y-6">
        <.panel title={gettext("Recipient")}>
          <p class="text-sm opacity-70">
            {gettext(
              "Who receives the goods, as their registration reads. It is written on the declaration and kept with this load, not on the location — a hospital renamed next month must not rewrite a paper already signed."
            )}
          </p>

          <div class="field-row mt-3">
            <label class="fieldset grow min-w-64">
              <span class="label">{gettext("Name")}</span>
              <input
                type="text"
                name="declaration[recipient_name]"
                value={@form[:recipient_name].value}
                class="input input-bordered w-full"
                required
              />
            </label>
            <label class="fieldset">
              <span class="label">{gettext("CNPJ")}</span>
              <input
                type="text"
                name="declaration[recipient_document]"
                value={TransportDeclaration.format_document(@form[:recipient_document].value)}
                class="input input-bordered w-56"
                inputmode="numeric"
              />
            </label>
          </div>

          <div class="field-row mt-3">
            <label class="fieldset grow min-w-64">
              <span class="label">{gettext("Address")}</span>
              <input
                type="text"
                name="declaration[recipient_address]"
                value={@form[:recipient_address].value}
                class="input input-bordered w-full"
              />
            </label>
            <label class="fieldset">
              <span class="label">{gettext("Postcode")}</span>
              <input
                type="text"
                name="declaration[recipient_postal_code]"
                value={@form[:recipient_postal_code].value}
                class="input input-bordered w-36"
              />
            </label>
          </div>
        </.panel>

        <.panel title={gettext("What the carrier asks for")}>
          <div class="field-row">
            <label class="fieldset">
              <span class="label">{gettext("Date")}</span>
              <input
                type="date"
                name="declaration[issued_on]"
                value={@form[:issued_on].value}
                class="input input-bordered"
                required
              />
            </label>
            <label class="fieldset">
              <span class="label">{gettext("Scheduling code")}</span>
              <input
                type="text"
                name="declaration[scheduling_code]"
                value={@form[:scheduling_code].value}
                class="input input-bordered w-40"
              />
            </label>
            <label class="fieldset">
              <span class="label">{gettext("Invoice number")}</span>
              <input
                type="text"
                name="declaration[invoice_number]"
                value={@form[:invoice_number].value}
                class="input input-bordered w-40"
              />
            </label>
            <label class="fieldset">
              <span class="label">{gettext("Reference")}</span>
              <input
                type="text"
                name="declaration[reference]"
                value={@form[:reference].value}
                class="input input-bordered w-32"
              />
            </label>
          </div>
        </.panel>

        <div class="flex flex-wrap items-center gap-3">
          <.button variant="primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save declaration")}
          </.button>

          <!-- Always rendered, disabled until there is something to print: a
               link that appears after saving would move the button under the
               thumb of whoever just pressed it. -->
          <.link
            navigate={~p"/shipments/#{@shipment.id}/declaracao/imprimir"}
            class={["btn", not @saved? && "btn-disabled pointer-events-none opacity-50"]}
          >
            {gettext("Print / save as PDF")}
          </.link>
        </div>
      </.form>

      <.panel title={gettext("What is travelling")} flush class="mt-6">
        <.data_table rows={@contents} row_id={&"line-#{&1.lot_id}-#{&1.box || "loose"}"}>
          <:empty>
            <.empty
              title={gettext("This load has no lines.")}
              note={gettext("A declaration is about goods, and this shipment moved none.")}
            />
          </:empty>

          <:col :let={row} label={gettext("Product")} emphasis={:identity}>
            {row.product}
            <span class="text-sm opacity-70">{row.unit}</span>
          </:col>

          <:col :let={row} label={gettext("Lot")}>{row.lot_number || "—"}</:col>
          <:col :let={row} label={gettext("Box")}>{row.box || gettext("loose")}</:col>

          <:col :let={row} label={gettext("Quantity")} align={:right} emphasis={:primary}>
            {quantity(row.quantity)}
          </:col>

          <:col :let={row} :if={@sees_money?} label={gettext("Total")} align={:right}>
            <.amount value={money(row.total)} />
          </:col>

          <:foot span={3}>
            {gettext("%{count} line(s)", count: length(@contents))}
          </:foot>
          <:foot align={:right}>{quantity(@totals.quantity)}</:foot>
          <:foot :if={@sees_money?} align={:right}>
            <.amount value={money(@totals.value)} />
          </:foot>
        </.data_table>
      </.panel>

      <p :if={@totals.unvalued > 0} class="alert alert-warning mt-4">
        {gettext(
          "%{count} line(s) arrived as a donation and carry no cost, so they are not in the declared value.",
          count: @totals.unvalued
        )}
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("save", %{"declaration" => params}, socket) do
    attrs =
      params
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.put(:user_id, socket.assigns.current_scope.user.id)

    case Outbound.save_declaration(socket.assigns.shipment, attrs) do
      {:ok, declaration} ->
        {:noreply,
         socket
         |> assign(:saved?, true)
         |> assign(:form, to_form(TransportDeclaration.changeset(declaration, %{})))
         |> put_flash(:info, gettext("Declaration saved."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:error, gettext("Check the fields marked in red."))}
    end
  end
end
