defmodule EstoqueOSWeb.StockLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    product = product_fixture(%{name: "Eletrodo ECG adulto"})
    lot = lot_fixture(%{product_id: product.id, lot_number: "114391U02"})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            quantity: Decimal.new(300),
            unit_cost: Decimal.new("0.2695")
          }
        ]
      })

    %{warehouse: warehouse, product: product, lot: lot}
  end

  test "shows what is in stock", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/stock")

    assert html =~ "Eletrodo ECG adulto"
    assert html =~ "114391U02"
    assert html =~ "Estoque Principal"
    assert html =~ "300"
  end

  # "Eu gostei de ter uma parte com várias badges nos itens do estoque." The
  # risk in that is a row wearing five and saying nothing, so they are ranked
  # and capped.
  describe "flags" do
    defp flags_cell(html, product) do
      # The whole row, tags stripped: asserting a badge is *absent* against raw
      # markup is how "vencido" gets satisfied by a class name.
      [row] = Regex.run(~r{<tr[^>]*>(?:(?!</tr>).)*#{product}.*?</tr>}s, html)
      String.replace(row, ~r{<[^>]*>}s, " ")
    end

    test "a row with nothing pressing says only how it arrived", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      cell = flags_cell(html, "Eletrodo ECG adulto")

      assert cell =~ "comprado"
      refute cell =~ "vencido"
      refute cell =~ "abaixo do mínimo"
    end

    test "the worst thing true about a row wins, and only two are shown", %{
      conn: conn,
      warehouse: warehouse
    } do
      product =
        product_fixture(%{
          name: "Gaze vencida",
          controlled: true,
          min_stock_override: Decimal.new(500)
        })

      lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2020-01-01]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "donation_in",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(5)}
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/stock")

      cell = flags_cell(html, "Gaze vencida")

      # Expired, below minimum, controlled and donation are all true of this
      # row. Two of them, the worst two — and "controlled" is now one of them,
      # because this column is the only place the row says so at all.
      assert cell =~ "vencido"
      assert cell =~ "controlado"
      refute cell =~ "abaixo do mínimo"
      refute cell =~ "doação"
    end

    test "running low is a fact about the product, not about one box", %{
      conn: conn,
      warehouse: warehouse
    } do
      product = product_fixture(%{name: "Seringa farta", min_stock_override: Decimal.new(10)})
      box = box_fixture(%{code: "SF01", location_id: warehouse.id})

      # Four in this box, a hundred in the location. The position is small; the
      # product is not short.
      for {quantity, box_id} <- [{4, box.id}, {100, nil}] do
        {:ok, _} =
          Inventory.post_transaction(%{
            type: "purchase_in",
            user_id: actor_id(),
            entries: [
              %{
                lot_id: lot_fixture(%{product_id: product.id}).id,
                location_id: warehouse.id,
                box_id: box_id,
                quantity: Decimal.new(quantity),
                unit_cost: Decimal.new("1.00")
              }
            ]
          })
      end

      {:ok, _view, html} = live(conn, ~p"/stock?search=Seringa+farta")

      refute flags_cell(html, "Seringa farta") =~ "abaixo do mínimo"
    end
  end

  test "downloads the spreadsheet", %{conn: conn} do
    conn = get(conn, ~p"/stock/export.xlsx")

    assert response_content_type(conn, :xlsx) =~ "spreadsheetml"
    assert ["attachment; filename=\"estoque-" <> _] = get_resp_header(conn, "content-disposition")
    assert byte_size(response(conn, 200)) > 0
  end

  test "reports bad lines instead of importing them", %{conn: conn, lot: lot} do
    binary =
      sheet([
        ["Produto", "Lote", "Local", "Quantidade"],
        ["Produto inexistente", "X", "Estoque Principal", 5]
      ])

    {:ok, view, _html} = live(conn, ~p"/reports/data")

    view
    |> file_input("#spreadsheet-import-form", :sheet, [
      %{
        name: "contagem.xlsx",
        content: binary,
        type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      }
    ])
    |> render_upload("contagem.xlsx")

    html = view |> element("#spreadsheet-import-form") |> render_submit()

    assert html =~ "Nada foi importado"
    assert html =~ "não está no catálogo"
    assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(300))
  end

  test "a counted spreadsheet adjusts stock", %{conn: conn, lot: lot} do
    binary =
      sheet([
        ["Produto", "Lote", "Local", "Quantidade"],
        ["Eletrodo ECG adulto", "114391U02", "Estoque Principal", 287]
      ])

    {:ok, view, _html} = live(conn, ~p"/reports/data")

    view
    |> file_input("#spreadsheet-import-form", :sheet, [
      %{
        name: "contagem.xlsx",
        content: binary,
        type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      }
    ])
    |> render_upload("contagem.xlsx")

    html = view |> element("#spreadsheet-import-form") |> render_submit()

    assert html =~ "1 lote(s) ajustado(s)"
    assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(287))
  end

  defp sheet(rows) do
    {:ok, {_name, binary}} =
      %Elixlsx.Workbook{sheets: [%Elixlsx.Sheet{name: "Estoque", rows: rows}]}
      |> Elixlsx.write_to_memory("contagem.xlsx")

    binary
  end
end
