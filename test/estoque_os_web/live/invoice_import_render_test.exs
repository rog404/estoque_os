defmodule EstoqueOSWeb.InvoiceImportRenderTest do
  @moduledoc """
  The import screen shipped once with strings that were never extracted, so it
  rendered in English for a Portuguese operator. These assertions are on the
  translated text on purpose: they fail the same way that bug did.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_operator

  test "names the three steps, so nobody leaves thinking the stock went up", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices/import")

    assert html =~ "Ler o XML"
    assert html =~ "Confirmar os itens"
    assert html =~ "Lançar no estoque"
  end

  test "states the accepted format and size before a file is chosen", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/invoices/import")

    assert html =~ "NF-e layout 4.00, até 8.0 MB"
  end

  test "will not submit with nothing attached", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/import")

    assert has_element?(view, "#upload-form button[disabled]")
  end
end
