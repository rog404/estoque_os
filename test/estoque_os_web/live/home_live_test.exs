defmodule EstoqueOSWeb.HomeLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits}

  setup :register_and_log_in_user

  setup do
    %{warehouse: location_fixture(%{name: "Estoque Principal", kind: "warehouse"})}
  end

  defp receive_stock(lot, location, quantity, opts \\ []) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity),
            unit_cost: opts[:unit_cost] && Decimal.new(opts[:unit_cost])
          }
        ]
      })
  end

  test "an empty install says what to do first", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Visão geral"
    assert html =~ "Nada se moveu ainda"
    assert html =~ "Nada vencendo na janela de alerta"
  end

  test "sums what is in stock and what it is worth", %{conn: conn, warehouse: warehouse} do
    product = product_fixture(%{name: "Eletrodo ECG adulto"})
    lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2029-01-31]})
    receive_stock(lot, warehouse, 300, unit_cost: "0.2695")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "300"
    assert html =~ "R$ 80,85"
  end

  test "lists stock about to expire, soonest first", %{conn: conn, warehouse: warehouse} do
    soon = product_fixture(%{name: "Bupivacaína 0,5%"})
    later = product_fixture(%{name: "Gaze estéril"})

    receive_stock(
      lot_fixture(%{product_id: soon.id, expires_on: Date.add(Date.utc_today(), 20)}),
      warehouse,
      10
    )

    receive_stock(
      lot_fixture(%{product_id: later.id, expires_on: Date.add(Date.utc_today(), 365)}),
      warehouse,
      10
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Bupivacaína 0,5%"
    assert html =~ "20 dia(s)"
    # Outside the 90-day window.
    refute html =~ "Gaze estéril"
  end

  test "flags stock that already expired", %{conn: conn, warehouse: warehouse} do
    product = product_fixture(%{name: "Soro fisiológico"})
    lot = lot_fixture(%{product_id: product.id, expires_on: Date.add(Date.utc_today(), -5)})
    receive_stock(lot, warehouse, 4)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "venceu em"
  end

  test "shows products below the mission minimum", %{conn: conn, warehouse: warehouse} do
    product = product_fixture(%{name: "Cânula de guedel", min_stock_override: Decimal.new(60)})
    receive_stock(lot_fixture(%{product_id: product.id}), warehouse, 12)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Cânula de guedel"
    assert html =~ "faltam 48"
  end

  test "a catalog product that never moved is not reported as missing", %{conn: conn} do
    product_fixture(%{name: "Fio de sutura 4-0", min_stock_override: Decimal.new(100)})

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ "Fio de sutura 4-0"
    assert html =~ "Todo produto com mínimo definido está coberto"
  end

  test "lists boxes nobody has counted", %{conn: conn, warehouse: warehouse} do
    box = box_fixture(%{code: "HM01", location_id: warehouse.id})
    receive_stock(lot_fixture(), warehouse, 5, box_id: box.id)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "HM01"
    assert html =~ "nunca contada"
  end

  test "reports recent movements", %{conn: conn, warehouse: warehouse} do
    receive_stock(lot_fixture(), warehouse, 7, unit_cost: "1.00")

    {:ok, _view, html} = live(conn, ~p"/")

    # The same ledger type, a different act: this one came in by hand, and the
    # log used to call it a posted invoice.
    assert html =~ "Entrada manual"
    refute html =~ "Nota fiscal lançada"
    assert html =~ "1 linha(s)"
  end

  # A warning that states a fact and stops there leaves the manager to find the
  # rows by hand, which is the same as not being told at all.
  describe "warnings lead somewhere" do
    # Overrides the auditor the outer setup signed in: this block is about the
    # manager's dashboard.
    setup :register_and_log_in_operator

    # Signed in as the manager on purpose. The alert belongs to the two roles
    # that decide what to do about a disputed count — chase the supplier, or
    # accept the loss — and the operator who already counted it three times
    # cannot act on being told again.
    test "a count that disagreed twice links to the box it was about", %{
      conn: conn,
      warehouse: warehouse
    } do
      box = box_fixture(%{code: "HM09", location_id: warehouse.id})
      lot = lot_fixture()
      receive_stock(lot, warehouse, 5, box_id: box.id)

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "adjustment",
          reason_code: "count_correction",
          review_reason: "count_diverged_twice",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(-1)
            }
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(href="/boxes/#{box.id}")
    end

    # The logistics operator counted it three times already. Telling them again
    # on every visit is noise they cannot act on, and the decision it asks for
    # — chase the supplier, or accept the loss — is not theirs to take.
    test "a disputed count is not on the operator's dashboard", %{
      conn: conn,
      warehouse: warehouse
    } do
      box = box_fixture(%{code: "HM10", location_id: warehouse.id})
      lot = lot_fixture()
      receive_stock(lot, warehouse, 5, box_id: box.id)

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "adjustment",
          reason_code: "count_correction",
          review_reason: "count_diverged_twice",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(-1)
            }
          ]
        })

      logistics = register_and_log_in_logistics(%{conn: conn})
      {:ok, _view, html} = live(logistics.conn, ~p"/")

      refute html =~ ~s(href="/boxes/#{box.id}")
    end

    test "lots with no lot data link to exactly those rows", %{conn: conn, warehouse: warehouse} do
      product = product_fixture(%{name: "Gaze doada"})
      lot = lot_fixture(%{product_id: product.id, needs_review: true})
      receive_stock(lot, warehouse, 5)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "sem dados de lote"
      assert html =~ ~s(href="/stock?review=on")

      # And the destination is filtered rather than being the whole stock list.
      other = product_fixture(%{name: "Seringa comprada"})
      receive_stock(lot_fixture(%{product_id: other.id}), warehouse, 5)

      {:ok, _view, stock} = live(conn, ~p"/stock?review=on")

      assert stock =~ "Gaze doada"
      refute stock =~ "Seringa comprada"
    end
  end

  test "signed-out visitors land on the login page", %{conn: _conn} do
    conn = build_conn()

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end

  describe "ready for the next mission" do
    test "says how many of each kit the warehouse covers, worst first", %{
      conn: conn,
      warehouse: warehouse
    } do
      box = box_fixture(%{code: "RD01", location_id: warehouse.id})

      gown = product_fixture(%{name: "Avental EG"})
      cannula = product_fixture(%{name: "Cânula de Guedel"})

      {:ok, _plenty} =
        Kits.create_kit(%{
          name: "Kit Simples",
          items: [%{description: "Avental EG", quantity: Decimal.new(1), product_id: gown.id}]
        })

      {:ok, _short} =
        Kits.create_kit(%{
          name: "Kit Travado",
          items: [
            %{description: "Avental EG", quantity: Decimal.new(1), product_id: gown.id},
            %{description: "Cânula de Guedel", quantity: Decimal.new(1), product_id: cannula.id}
          ]
        })

      lot = lot_fixture(%{product_id: gown.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              box_id: box.id,
              quantity: Decimal.new(20)
            }
          ]
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Pronto para a próxima missão"
      assert html =~ "Kit Travado"
      assert html =~ "Kit Simples"

      # A warehouse can look full and still not complete one kit, because a
      # single component ran out. The blocked kit is named first.
      assert html =~ "limitado por: Cânula de Guedel"
      {travado, _} = :binary.match(html, "Kit Travado")
      {simples, _} = :binary.match(html, "Kit Simples")
      assert travado < simples
    end

    test "says so when there is no kit to be ready for", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Nenhum kit cadastrado"
    end
  end
end
