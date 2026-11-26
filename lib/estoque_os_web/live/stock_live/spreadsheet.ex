defmodule EstoqueOSWeb.StockLive.Spreadsheet do
  @moduledoc """
  The spreadsheet round trip, on a page of its own under Reports. What comes
  back in is a *count*: the sheet states what is physically on the shelf and
  only the difference is posted, as an adjustment. It never adds stock the way
  an invoice does.

  An upload is previewed, never posted straight away. On the preview the
  operator creates products the catalog lacks and excludes bad lines, so only
  the lines that are right get imported.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Reports

  def viewer_events, do: ~w(validate)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, reset(socket)}
  end

  defp reset(socket) do
    socket
    |> assign(:page_title, gettext("Data"))
    |> assign(:preview, nil)
    |> assign(:rows, [])
    |> assign(:excluded, MapSet.new())
    |> assign(:excluded_rows, [])
    |> assign(:create_missing, false)
    |> assign(:import_result, nil)
    |> assign(:import_errors, [])
    |> allow_upload(:sheet,
      accept: ~w(.xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet),
      max_entries: 1,
      max_file_size: 16_000_000
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-xl space-y-6">
        <.header back_to={~p"/stock"} back_label={gettext("Stock")}>
          {gettext("Import and export data")}
          <:subtitle>
            {gettext("Take the stock out to a sheet, or bring a physical count back in.")}
          </:subtitle>
        </.header>

        <div :if={is_nil(@preview)} class="rounded-box border border-base-300 p-4 space-y-3">
          <.spreadsheet_actions
            upload={@uploads.sheet}
            export_path={~p"/stock/export.xlsx"}
            count_sheet_path={~p"/stock/count-sheet.xlsx"}
            template_path={~p"/stock/template.xlsx"}
            initial_import={true}
            id="spreadsheet-import-form"
          />
        </div>

        <.spreadsheet_preview :if={@preview} preview={@preview} excluded={@excluded_rows} />

        <.spreadsheet_outcome result={@import_result} errors={@import_errors} />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("preview", params, socket) do
    create_missing = params["create_missing"] == "true"

    case consume_uploaded_entries(socket, :sheet, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [binary] ->
        start_preview(socket, binary, create_missing)

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Pick a spreadsheet first."))}
    end
  end

  def handle_event("exclude", %{"line" => line}, socket) do
    {:noreply, rebuild(socket, MapSet.put(socket.assigns.excluded, to_line(line)))}
  end

  def handle_event("restore", %{"line" => line}, socket) do
    {:noreply, rebuild(socket, MapSet.delete(socket.assigns.excluded, to_line(line)))}
  end

  def handle_event("create_product", %{"line" => line}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1.line == to_line(line)))

    case row && row.product && Reports.create_import_product(row.product) do
      {:ok, product} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Product \"%{name}\" created.", name: product.name))
         |> rebuild(socket.assigns.excluded)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("The product could not be created."))}
    end
  end

  def handle_event("confirm", _params, socket) do
    %{rows: rows, excluded: excluded, create_missing: create_missing} = socket.assigns
    user_id = socket.assigns.current_scope.user.id
    kept = Enum.reject(rows, &MapSet.member?(excluded, &1.line))

    case Reports.import_counted_rows(kept, user_id: user_id, create_missing: create_missing) do
      {:ok, result} ->
        {:noreply, socket |> reset() |> assign(:import_result, result)}

      {:error, errors} when is_list(errors) ->
        {:noreply, socket |> assign(:import_errors, errors) |> assign(:preview, nil)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The spreadsheet could not be read."))}
    end
  end

  def handle_event("start_over", _params, socket), do: {:noreply, reset(socket)}

  defp start_preview(socket, binary, create_missing) do
    case Reports.StockWorkbook.import_rows(binary) do
      {:ok, rows} ->
        {:noreply,
         socket
         |> assign(:rows, rows)
         |> assign(:create_missing, create_missing)
         |> assign(:import_result, nil)
         |> assign(:import_errors, [])
         |> rebuild(MapSet.new())}

      {:error, {:missing_columns, columns}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The spreadsheet is missing these columns: %{columns}",
             columns: Enum.join(columns, ", ")
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("The spreadsheet could not be read."))}
    end
  end

  defp rebuild(socket, excluded) do
    %{rows: rows, create_missing: create_missing} = socket.assigns
    {excluded_rows, kept} = Enum.split_with(rows, &MapSet.member?(excluded, &1.line))

    socket
    |> assign(:excluded, excluded)
    |> assign(:excluded_rows, excluded_rows)
    |> assign(:preview, Reports.preview_rows(kept, create_missing: create_missing))
  end

  defp to_line(line) when is_integer(line), do: line
  defp to_line(line) when is_binary(line), do: String.to_integer(line)
end
