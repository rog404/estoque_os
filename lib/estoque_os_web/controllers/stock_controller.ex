defmodule EstoqueOSWeb.StockController do
  @moduledoc """
  Serves the stock spreadsheet. A controller rather than a LiveView because
  LiveView cannot hand a browser a binary download.
  """

  use EstoqueOSWeb, :controller

  alias EstoqueOS.Reports

  def export(conn, params) do
    location_id =
      with value when is_binary(value) <- params["location_id"],
           {id, _rest} <- Integer.parse(value) do
        id
      else
        _ -> nil
      end

    # Logistics must still export (they send it back counted), minus the cost columns.
    money? = EstoqueOSWeb.UserAuth.sees_money?(conn.assigns[:current_scope])

    # Same narrowing as the stock screen: the file and the page must agree.
    segment =
      EstoqueOS.Accounts.Scope.segment(
        conn.assigns[:current_scope],
        segment_param(params["segment"])
      )

    case Reports.export_stock(location_id: location_id, segment: segment, money: money?) do
      {:ok, binary} ->
        conn
        |> put_resp_content_type(
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        |> send_download({:binary, binary}, filename: filename())

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("The spreadsheet could not be generated."))
        |> redirect(to: ~p"/stock")
    end
  end

  def count_sheet(conn, params) do
    location_id =
      with value when is_binary(value) <- params["location_id"],
           {id, _rest} <- Integer.parse(value) do
        id
      else
        _ -> nil
      end

    segment =
      EstoqueOS.Accounts.Scope.segment(
        conn.assigns[:current_scope],
        segment_param(params["segment"])
      )

    case Reports.export_count_sheet(location_id: location_id, segment: segment) do
      {:ok, binary} ->
        conn
        |> put_resp_content_type(
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        |> send_download({:binary, binary}, filename: count_sheet_filename())

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("The spreadsheet could not be generated."))
        |> redirect(to: ~p"/stock")
    end
  end

  def template(conn, _params) do
    case EstoqueOS.Reports.StockWorkbook.template() do
      {:ok, binary} ->
        conn
        |> put_resp_content_type(
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        |> send_download({:binary, binary}, filename: "modelo-estoque.xlsx")

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("The template could not be generated."))
        |> redirect(to: ~p"/stock")
    end
  end

  defp segment_param(value) do
    if value in EstoqueOS.Catalog.Product.segments(), do: value
  end

  defp filename do
    "estoque-#{Calendar.strftime(Date.utc_today(), "%Y-%m-%d")}.xlsx"
  end

  defp count_sheet_filename do
    "contagem-#{Calendar.strftime(Date.utc_today(), "%Y-%m-%d")}.xlsx"
  end
end
