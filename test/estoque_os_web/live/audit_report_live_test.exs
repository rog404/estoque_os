defmodule EstoqueOSWeb.AuditReportLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup :register_and_log_in_user

  setup %{user: user} do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    controlled = product_fixture(%{name: "Fentanila 50mcg", controlled: true})
    plain = product_fixture(%{name: "Eletrodo ECG adulto"})

    controlled_lot = lot_fixture(%{product_id: controlled.id, expires_on: ~D[2027-06-30]})
    plain_lot = lot_fixture(%{product_id: plain.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: user.id,
        entries: [
          %{
            lot_id: plain_lot.id,
            location_id: warehouse.id,
            quantity: Decimal.new(300),
            unit_cost: Decimal.new("0.2695")
          },
          %{lot_id: controlled_lot.id, location_id: warehouse.id, quantity: Decimal.new(20)}
        ]
      })

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "adjustment",
        reason_code: "damage",
        user_id: user.id,
        notes: "Caixa molhada no transporte",
        entries: [
          %{lot_id: plain_lot.id, location_id: warehouse.id, quantity: Decimal.new(-13)}
        ]
      })

    %{warehouse: warehouse, mission: mission, plain_lot: plain_lot}
  end

  test "summarises movements by type", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/reports/audit")

    assert html =~ "Relatório de auditoria"
    assert html =~ "Movimentações por tipo"
    assert html =~ "Nota fiscal lançada"
    assert html =~ "Ajuste"
  end

  test "gives adjustments their own block, with the reason", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/reports/audit")

    assert html =~ "Ajustes por motivo"
    assert html =~ "avaria"
    assert html =~ "-13"
  end

  test "lists controlled substances separately", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/reports/audit")

    assert html =~ "Controlados em estoque"
    assert html =~ "Fentanila 50mcg"
    # The ordinary product is not in the controlled block.
    controlled_block =
      html
      |> String.split("Controlados em estoque")
      |> Enum.at(1)
      |> String.split("Registro de movimentações")
      |> hd()

    refute controlled_block =~ "Eletrodo ECG adulto"
  end

  test "shows who did what, with the note on record", %{conn: conn, user: user} do
    {:ok, _view, html} = live(conn, ~p"/reports/audit")

    assert html =~ "Registro de movimentações"
    assert html =~ user.email
    assert html =~ "Caixa molhada no transporte"
  end

  test "filters by period", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports/audit")

    html =
      view
      |> element("#period-form")
      |> render_change(%{
        "from" => Date.to_iso8601(Date.add(Date.utc_today(), -400)),
        "to" => Date.to_iso8601(Date.add(Date.utc_today(), -300)),
        "type" => ""
      })

    assert html =~ "Nada se moveu neste período"
    assert html =~ "Nenhum ajuste neste período"
  end

  test "filters by movement type", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports/audit")

    html =
      view
      |> element("#period-form")
      |> render_change(%{
        "from" => Date.to_iso8601(Date.add(Date.utc_today(), -30)),
        "to" => Date.to_iso8601(Date.utc_today()),
        "type" => "adjustment"
      })

    # The log now shows only the adjustment, but the summary still covers all.
    assert html =~ "Caixa molhada no transporte"
    assert html =~ "Movimentações por tipo"
  end
end
