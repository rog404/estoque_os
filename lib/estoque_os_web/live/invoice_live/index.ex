defmodule EstoqueOSWeb.InvoiceLive.Index do
  @moduledoc """
  Invoices imported so far, newest first.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Invoices

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Invoices"))
     |> assign(:invoices, Invoices.list_invoices())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Invoices")}
        <:subtitle>{gettext("Everything imported from supplier XMLs.")}</:subtitle>
        <:actions>
          <.link navigate={~p"/invoices/import"} class="btn btn-primary">
            {gettext("Import invoice")}
          </.link>
        </:actions>
      </.header>

      <.panel title={gettext("Invoices")} flush>
        <.data_table rows={@invoices} row_id={&"invoice-#{&1.id}"}>
          <:empty>
            <.empty
              title={gettext("No invoice imported yet.")}
              note={
                gettext(
                  "The XML the supplier sends carries the lots, the pack sizes and the prices. Importing it is what replaces the week of typing."
                )
              }
            >
              <:actions>
                <.link navigate={~p"/invoices/import"} class="btn btn-primary">
                  {gettext("Import invoice")}
                </.link>
              </:actions>
            </.empty>
          </:empty>

          <:col :let={invoice} label={gettext("Number")} emphasis={:identity}>
            <.link navigate={~p"/invoices/#{invoice}"} class="link link-hover">
              {invoice.number}
            </.link>
          </:col>

          <:col :let={invoice} label={gettext("Supplier")}>{invoice.supplier.legal_name}</:col>

          <:col :let={invoice} label={gettext("Issued on")}>
            {Calendar.strftime(invoice.issued_on, "%d/%m/%Y")}
          </:col>

          <:col :let={invoice} label={gettext("Total")} align={:right} emphasis={:primary}>
            {money(invoice.total)}
          </:col>

          <:col :let={invoice} label={gettext("Status")}>
            <span class={["badge", status_class(invoice.status)]}>
              {status_label(invoice.status)}
            </span>
          </:col>
        </.data_table>
      </.panel>
    </Layouts.app>
    """
  end

  defp status_label("parsed"), do: gettext("Pending confirmation")
  defp status_label("matched"), do: gettext("Ready to post")
  defp status_label("posted"), do: gettext("Posted to stock")
  defp status_label("cancelled"), do: gettext("Cancelled")

  defp status_class("posted"), do: "badge-success"
  defp status_class("cancelled"), do: "badge-error"
  defp status_class(_), do: "badge-warning"
end
