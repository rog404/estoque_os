defmodule EstoqueOSWeb.AuditLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Repo
  alias EstoqueOS.Inventory.Locations

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    controlled_box = box_fixture(%{code: "AUC1", location_id: warehouse.id})
    controlled = product_fixture(%{name: "Fentanila 50mcg", controlled: true})
    controlled_lot = lot_fixture(%{product_id: controlled.id})

    plain_box = box_fixture(%{code: "AU01", location_id: warehouse.id})
    plain = product_fixture(%{name: "Eletrodo ECG adulto"})
    plain_lot = lot_fixture(%{product_id: plain.id, expires_on: ~D[2029-01-31]})

    for {box, lot, quantity} <- [
          {controlled_box, controlled_lot, 20},
          {plain_box, plain_lot, 300}
        ] do
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              box_id: box.id,
              location_id: warehouse.id,
              quantity: Decimal.new(quantity)
            }
          ]
        })
    end

    %{
      warehouse: warehouse,
      controlled_box: controlled_box,
      plain_box: plain_box,
      plain_lot: plain_lot
    }
  end

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} -> index
      :nomatch -> flunk("#{needle} is not on the page")
    end
  end

  describe "index" do
    test "ranks the boxes and says why", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ "Mini-auditoria"
      assert html =~ "AUC1"
      assert html =~ "1 item(ns) controlado(s)"
      assert html =~ "nunca contada"

      # The controlled box is listed first.
      assert position(html, "AUC1") < position(html, "AU01")
    end

    test "says so when nothing is boxed yet", %{
      conn: conn,
      controlled_box: controlled,
      plain_box: plain
    } do
      for box <- [controlled, plain] do
        for row <- Locations.box_contents(box) do
          {:ok, _} =
            Inventory.post_transaction(%{
              type: "manual_out",
              user_id: actor_id(),
              entries: [
                %{
                  lot_id: row.lot_id,
                  box_id: box.id,
                  location_id: row.location_id,
                  quantity: Decimal.negate(row.quantity)
                }
              ]
            })
        end
      end

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ "Nenhuma caixa tem estoque ainda"
    end
  end

  describe "counting a box" do
    test "shows what the ledger presumes", %{conn: conn, plain_box: box} do
      {:ok, _view, html} = live(conn, ~p"/audit/#{box}")

      assert html =~ "Contagem da caixa AU01"
      assert html =~ "Eletrodo ECG adulto"
      assert html =~ "300"
      assert html =~ "nunca contada"
    end

    test "records a short count as a correction", %{
      conn: conn,
      plain_box: box,
      plain_lot: lot
    } do
      {:ok, view, _html} = live(conn, ~p"/audit/#{box}")

      # 300 presumed, 287 counted: a divergence, so the flow asks for the
      # recount before it will write anything.
      view |> element("#count-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "287"}})
      view |> element("#recount-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "287"}})

      html = view |> element("#commit-form") |> render_submit()

      assert html =~ "sinalizada para o gestor"
      assert html =~ "1 posição(ões) corrigida(s)"

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(287))
      assert Repo.reload!(box).last_verified_at
    end

    test "a blank line is not counted", %{conn: conn, plain_box: box, plain_lot: lot} do
      {:ok, view, _html} = live(conn, ~p"/audit/#{box}")

      view |> element("#count-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "   "}})

      html = view |> element("#commit-form") |> render_submit()

      assert html =~ "0 posição(ões) corrigida(s) de 0 contada(s)"
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(300))
      # The box is still stamped as looked at.
      assert Repo.reload!(box).last_verified_at
    end

    test "a counted box stops claiming it was never counted", %{
      conn: conn,
      plain_box: box,
      plain_lot: lot
    } do
      {:ok, view, _html} = live(conn, ~p"/audit/#{box}")
      view |> element("#count-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "300"}})
      view |> element("#commit-form") |> render_submit()

      {:ok, _view, html} = live(conn, ~p"/audit")

      # Both boxes are still listed, but only the untouched one is overdue.
      assert position(html, "AUC1") < position(html, "AU01")
      assert html =~ "nunca contada"

      counted_half = String.slice(html, position(html, "AU01")..-1//1)
      refute counted_half =~ "nunca contada"
    end
  end
end
