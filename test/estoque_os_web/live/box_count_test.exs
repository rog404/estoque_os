defmodule EstoqueOSWeb.BoxCountTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Repo

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

  describe "the box list is the queue" do
    test "ranks the boxes and says why", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/boxes")

      assert html =~ "AUC1"
      assert html =~ "1 item(ns) controlado(s)"
      assert html =~ "nunca contada"

      # The controlled box is listed first. There is no second page ranking the
      # same boxes any more: the list somebody already opens *is* the order.
      assert position(html, "AUC1") < position(html, "AU01")
    end

    test "the guided list is gone, and so is its address", %{conn: conn} do
      # A dead link is worse than a missing one: it looks like a screen that
      # broke rather than a screen that went.
      assert conn |> get("/audit") |> Map.fetch!(:status) == 404
    end

    test "a box with nothing in it sinks to the bottom", %{
      conn: conn,
      warehouse: warehouse
    } do
      _empty = box_fixture(%{code: "AA00", location_id: warehouse.id})

      {:ok, _view, html} = live(conn, ~p"/boxes")

      # Alphabetically it would open the list. There is nothing in it to count,
      # so it is the last thing worth walking to.
      assert position(html, "AUC1") < position(html, "AA00")
      assert position(html, "AU01") < position(html, "AA00")
    end
  end

  describe "counting a box" do
    test "shows what the ledger presumes", %{conn: conn, plain_box: box} do
      {:ok, _view, html} = live(conn, ~p"/boxes/#{box}/count")

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
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}/count")

      # 300 presumed, 287 counted: a divergence, so the flow asks for the
      # recount before it will write anything.
      view |> element("#count-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "287"}})
      view |> element("#recount-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "287"}})

      html = view |> element("#commit-form") |> render_submit()

      assert html =~ "sinalizada para o gestor"
      assert html =~ "1 lote(s) corrigido(s)"

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(287))
      assert Repo.reload!(box).last_verified_at
    end

    # The dialog counted every line somebody typed into, so a count where one of
    # two lines agreed with the ledger promised "2 lote(s) mudam" and then
    # recorded "1 lote(s) corrigido(s) de 2 contado(s)". What the confirmation
    # promises is the last thing read before an irreversible write, so it has to
    # be the number the write actually produces.
    test "the confirmation counts what changes, not what was typed", %{
      conn: conn,
      warehouse: warehouse,
      plain_box: box,
      plain_lot: agreeing
    } do
      other = product_fixture(%{name: "Luva de procedimento"})
      diverging = lot_fixture(%{product_id: other.id, expires_on: ~D[2029-06-30]})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: diverging.id,
              box_id: box.id,
              location_id: warehouse.id,
              quantity: Decimal.new(50)
            }
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}/count")

      counts = %{"#{agreeing.id}" => "300", "#{diverging.id}" => "44"}
      view |> element("#count-form") |> render_submit(%{"counts" => counts})

      html =
        view
        |> element("#recount-form")
        |> render_submit(%{"counts" => %{"#{diverging.id}" => "44"}})

      assert html =~ "1 lote(s) mudam"
      refute html =~ "2 lote(s) mudam"

      html = view |> element("#commit-form") |> render_submit()
      assert html =~ "1 lote(s) corrigido(s) de 2 contado(s)"
    end

    test "a blank line is not counted", %{conn: conn, plain_box: box, plain_lot: lot} do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}/count")

      view |> element("#count-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "   "}})

      html = view |> element("#commit-form") |> render_submit()

      assert html =~ "0 lote(s) corrigido(s) de 0 contado(s)"
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(300))
      # The box is still stamped as looked at.
      assert Repo.reload!(box).last_verified_at
    end

    test "a counted box stops claiming it was never counted", %{
      conn: conn,
      plain_box: box,
      plain_lot: lot
    } do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}/count")
      view |> element("#count-form") |> render_submit(%{"counts" => %{"#{lot.id}" => "300"}})
      view |> element("#commit-form") |> render_submit()

      {:ok, _view, html} = live(conn, ~p"/boxes")

      # Both boxes are still listed, but only the untouched one is overdue.
      assert position(html, "AUC1") < position(html, "AU01")
      assert html =~ "nunca contada"

      counted_half = String.slice(html, position(html, "AU01")..-1//1)
      refute counted_half =~ "nunca contada"
    end
  end
end
