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

    # The file the logistics operator counts on leaves without the cost columns.
    # Refusing them the export is not an option — sending it back counted is
    # their job — so what leaves is the sheet they have always had on paper.
    money? = EstoqueOSWeb.UserAuth.sees_money?(conn.assigns[:current_scope])

    # The same narrowing the stock screen applies, and read from the same place:
    # a role confined to one stock must not be able to walk out of it by asking
    # for the file instead of the page. `on_mount` never runs for a controller,
    # which is exactly how a hole like this gets left.
    segment =
      EstoqueOS.Accounts.Scope.segment(conn.assigns[:current_scope]) ||
        segment_param(params["segment"])

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

  defp segment_param(value) do
    if value in EstoqueOS.Catalog.Product.segments(), do: value
  end

  defp filename do
    "estoque-#{Calendar.strftime(Date.utc_today(), "%Y-%m-%d")}.xlsx"
  end
end
