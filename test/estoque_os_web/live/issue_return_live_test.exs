defmodule EstoqueOSWeb.IssueReturnLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Locations

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

    warehouse_box = box_fixture(%{code: "IR04", location_id: warehouse.id})
    mission_box = box_fixture(%{code: "IR01", location_id: mission.id})

    product = product_fixture(%{name: "Eletrodo ECG adulto"})
    warehouse_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2027-03-31]})
    mission_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-03-31]})

    stock_in(warehouse_lot, warehouse, 100)
    stock_in(mission_lot, mission, 80, box_id: mission_box.id)

    %{
      warehouse: warehouse,
      mission: mission,
      warehouse_box: warehouse_box,
      mission_box: mission_box,
      warehouse_lot: warehouse_lot,
      mission_lot: mission_lot
    }
  end

  defp stock_in(lot, location, quantity, opts \\ []) do
    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            box_id: opts[:box_id],
            quantity: Decimal.new(quantity)
          }
        ]
      })
  end

  describe "manual issue" do
    test "searches the catalog and issues by quantity", %{
      conn: conn,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      html =
        view
        |> element("#search-form")
        |> render_change(%{"query" => "eletrodo", "location_id" => "#{warehouse.id}"})

      assert html =~ "Eletrodo ECG adulto"

      html = view |> element("button", "Eletrodo ECG adulto") |> render_click()
      assert html =~ "100 disponíveis aqui"

      # Nothing is written until the basket is confirmed.
      html = view |> element("#issue-form") |> render_submit(%{"quantity" => "30"})

      assert html =~ "Saindo juntos"
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(100))

      view |> form("#destination-form", %{"destination" => "triage"}) |> render_change()

      html =
        view
        |> element("#basket-form")
        |> render_submit(%{})

      assert html =~ "1 item(ns) baixado(s)"
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(70))
    end

    test "lists what is actually at the location before anything is typed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/issue")

      assert html =~ "O que está aqui agora"
      assert html =~ "Eletrodo ECG adulto"
      assert html =~ "100"
    end

    test "a product with nothing here is not offered", %{conn: conn, mission: mission} do
      absent = product_fixture(%{name: "Cânula de Guedel"})
      lot = lot_fixture(%{product_id: absent.id})
      stock_in(lot, mission, 25)

      {:ok, _view, html} = live(conn, ~p"/issue")

      assert html =~ "Eletrodo ECG adulto"
      refute html =~ "Cânula de Guedel"
    end

    test "picking from the shelf opens the same form as the search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      # "Separar", not "Adicionar": this screen takes goods out of stock.
      html = view |> element("button", "Separar") |> render_click()

      assert html =~ "disponíveis aqui" or html =~ "Eletrodo ECG adulto"
      assert has_element?(view, "#issue-form")
    end

    test "a line added by mistake is removed, not corrected", %{
      conn: conn,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("button", "Separar") |> render_click()
      view |> element("#issue-form") |> render_submit(%{"quantity" => "30"})

      # Icon-only button, found by its accessible name.
      html = view |> element(~s(button[aria-label^="Remover"])) |> render_click()

      refute html =~ "Saindo juntos"
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(100))
    end

    test "several products leave as one movement", %{conn: conn, warehouse: warehouse} do
      other = product_fixture(%{name: "Seringa 10ml"})
      lot = lot_fixture(%{product_id: other.id})
      stock_in(lot, warehouse, 50)

      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => "eletrodo"})
      view |> element("button", "Eletrodo ECG adulto") |> render_click()
      view |> element("#issue-form") |> render_submit(%{"quantity" => "10"})

      view |> element("#search-form") |> render_change(%{"query" => "seringa"})
      view |> element("button", "Seringa 10ml") |> render_click()
      view |> element("#issue-form") |> render_submit(%{"quantity" => "5"})

      view |> form("#destination-form", %{"destination" => "pacu"}) |> render_change()
      view |> element("#basket-form") |> render_submit(%{})

      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(135))

      assert [transaction] = manual_issues()
      assert length(transaction.entries) == 2
    end

    test "says how much is missing", %{conn: conn, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view
      |> element("#search-form")
      |> render_change(%{"query" => "eletrodo", "location_id" => "#{warehouse.id}"})

      view |> element("button", "Eletrodo ECG adulto") |> render_click()

      view |> element("#issue-form") |> render_submit(%{"quantity" => "500"})
      view |> form("#destination-form", %{"destination" => "pacu"}) |> render_change()
      html = view |> element("#basket-form") |> render_submit(%{})

      assert html =~ "faltam 400"
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(100))
    end
  end

  defp manual_issues do
    import Ecto.Query

    EstoqueOS.Inventory.Transaction
    |> where([t], t.type == "manual_out")
    |> preload(:entries)
    |> EstoqueOS.Repo.all()
  end

  # Only the "into box" field: the page's other selects are legitimately preselected.
  defp box_select(html) do
    case Regex.run(~r{<input[^>]*to_box_code[^>]*>}s, html) do
      [field] -> field
      nil -> flunk("no box field on the page")
    end
  end

  describe "mission return" do
    test "lists what the ledger believes is still out there", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/returns")

      assert html =~ "Retorno de missão"
      assert html =~ "Eletrodo ECG adulto"
      assert html =~ "IR01"
    end

    # After a mission the ledger is only a hypothesis; a prefilled answer measures nothing.
    test "counts blind: the expected quantity is neither shown nor prefilled", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/returns")

      refute html =~ "O livro diz"

      assert [field] = Regex.run(~r{<input[^>]*name="lines\[0\]\[quantity\]"[^>]*>}, html)
      assert field =~ ~s(value="")
      refute field =~ ~s(value="80")
      assert field =~ "não contada"
    end

    test "a manager may ask for the expected figure, on purpose", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/returns")

      html = render_click(view, "reveal", %{})

      assert html =~ "O livro diz"
      assert html =~ "esperado à vista"
    end

    # "O que não voltou foi usado" is ticked by default, so a blank read as zero
    # would write the whole mission off as consumed.
    test "a blank sheet is refused, not read as nothing came back", %{
      conn: conn,
      mission_lot: mission_lot,
      mission: mission
    } do
      {:ok, view, _html} = live(conn, ~p"/returns")

      before = Inventory.balance(lot_id: mission_lot.id, location_id: mission.id)

      html =
        view
        |> form("#return-form", %{
          "lines" => %{"0" => %{"quantity" => "", "to_box_code" => ""}},
          "consume_missing" => "true"
        })
        |> render_submit()

      assert html =~ "Conte pelo menos uma linha"

      assert Decimal.equal?(
               Inventory.balance(lot_id: mission_lot.id, location_id: mission.id),
               before
             )
    end

    test "warns that what did not come back will be written off", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/returns")

      assert html =~ "Receber este retorno?"
      assert html =~ "baixado como consumido na missão"
    end

    test "preselects the warehouse box that already holds the product", %{
      conn: conn,
      warehouse: warehouse,
      warehouse_box: warehouse_box,
      warehouse_lot: warehouse_lot
    } do
      stock_in(warehouse_lot, warehouse, 10, box_id: warehouse_box.id)

      {:ok, _view, html} = live(conn, ~p"/returns")

      assert box_select(html) =~ ~s(value="#{warehouse_box.code}")
      assert html =~ "já tem Eletrodo ECG adulto"
    end

    test "leaves the box empty when nothing at the destination suggests one", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/returns")

      refute box_select(html) =~ ~r/value="[A-Z]/
    end

    test "receives a short return into a different box", %{
      conn: conn,
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      warehouse_box: warehouse_box,
      mission_lot: mission_lot
    } do
      {:ok, view, _html} = live(conn, ~p"/returns")

      html =
        view
        |> element("#return-form")
        |> render_submit(%{
          "consume_missing" => "on",
          "lines" => %{
            "0" => %{
              "lot_id" => "#{mission_lot.id}",
              "from_box_id" => "#{mission_box.id}",
              "expected" => "80",
              "quantity" => "60",
              "to_box_code" => warehouse_box.code
            }
          }
        })

      assert html =~ "Retorno recebido"
      assert Decimal.equal?(Inventory.balance(box_id: warehouse_box.id), Decimal.new(60))
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(0))
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(160))
    end

    # All invented boxes are named at once; asking one by one waves the last through.
    test "boxes the return would invent are named before they are created", %{
      conn: conn,
      mission: mission,
      warehouse: warehouse,
      mission_box: mission_box,
      mission_lot: mission_lot
    } do
      {:ok, view, _html} = live(conn, ~p"/returns")

      submit = fn ->
        view
        |> element("#return-form")
        |> render_submit(%{
          "consume_missing" => "on",
          "lines" => %{
            "0" => %{
              "lot_id" => "#{mission_lot.id}",
              "from_box_id" => "#{mission_box.id}",
              "expected" => "80",
              "quantity" => "80",
              "to_box_code" => "WH9O"
            }
          }
        })
      end

      html = submit.()

      assert html =~ "WH9O"
      refute Enum.any?(Locations.list_boxes(warehouse.id), &(&1.code == "WH9O"))
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(80))

      view |> element("#confirm-new-box") |> render_click()

      created = Enum.find(Locations.list_boxes(warehouse.id), &(&1.code == "WH9O"))
      assert created
      assert Decimal.equal?(Inventory.balance(box_id: created.id), Decimal.new(80))
    end

    test "refuses to receive more than went out", %{
      conn: conn,
      mission: mission,
      mission_box: mission_box,
      mission_lot: mission_lot
    } do
      {:ok, view, _html} = live(conn, ~p"/returns")

      html =
        view
        |> element("#return-form")
        |> render_submit(%{
          "lines" => %{
            "0" => %{
              "lot_id" => "#{mission_lot.id}",
              "from_box_id" => "#{mission_box.id}",
              "expected" => "80",
              "quantity" => "100",
              "to_box_code" => ""
            }
          }
        })

      assert html =~ "voltou mais do que saiu"
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(80))
    end
  end
end
