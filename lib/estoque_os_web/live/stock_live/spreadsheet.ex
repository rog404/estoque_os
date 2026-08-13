defmodule EstoqueOSWeb.StockLive.Spreadsheet do
  @moduledoc """
  The spreadsheet round trip on a page of its own.

  Same two actions the stock screen offers in a dropdown, reachable without
  first finding the stock screen. What comes back in is a *count*: the sheet
  states what is physically on the shelf, and only the difference is posted,
  as an adjustment. It never adds stock the way an invoice does.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Reports

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Import data"))
     |> assign(:import_result, nil)
     |> assign(:import_errors, [])
     |> allow_upload(:sheet,
       accept: ~w(.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet),
       max_entries: 1,
       max_file_size: 16_000_000
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-xl space-y-6">
        <.header back_to={~p"/stock"} back_label={gettext("Stock")}>
          {gettext("Import data")}
          <:subtitle>
            {gettext("Take the stock out to a sheet, or bring a physical count back in.")}
          </:subtitle>
        </.header>

        <div class="rounded-box border border-base-300 p-4 space-y-3">
          <.spreadsheet_actions
            upload={@uploads.sheet}
            export_path={~p"/stock/export.xlsx"}
            id="spreadsheet-import-form"
          />
        </div>

        <.spreadsheet_outcome result={@import_result} errors={@import_errors} />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("import", _params, socket) do
    user_id = socket.assigns.current_scope.user.id

    case consume_uploaded_entries(socket, :sheet, fn %{path: path}, _entry ->
           {:ok, path |> File.read!() |> Reports.import_stock(user_id: user_id)}
         end) do
      [{:ok, result}] ->
        {:noreply, socket |> assign(:import_result, result) |> assign(:import_errors, [])}

      [{:error, errors}] when is_list(errors) ->
        {:noreply, socket |> assign(:import_errors, errors) |> assign(:import_result, nil)}

      [{:error, {:missing_columns, columns}}] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The spreadsheet is missing these columns: %{columns}",
             columns: Enum.join(columns, ", ")
           )
         )}

      [{:error, _reason}] ->
        {:noreply, put_flash(socket, :error, gettext("The spreadsheet could not be read."))}

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Pick a spreadsheet first."))}
    end
  end
end
