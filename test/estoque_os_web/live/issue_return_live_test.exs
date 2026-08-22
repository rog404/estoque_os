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

      # The quantity goes into the basket; nothing is written until it is
      # confirmed, which is what lets a wrong line be removed instead of
      # corrected by an adjustment on the record forever.
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

    # The operator often does not know the catalog name — they know they are
    # standing in front of a shelf.
    test "lists what is actually at the location before anything is typed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/issue")

      assert html =~ "O que está aqui agora"
      assert html =~ "Eletrodo ECG adulto"
      assert html =~ "100"
    end

    test "a product with nothing here is not offered", %{conn: conn, mission: mission} do
      # Absent from the warehouse listing on its own merits: this product's
      # stock is all at the mission.
      absent = product_fixture(%{name: "Cânula de Guedel"})
      lot = lot_fixture(%{product_id: absent.id})
      stock_in(lot, mission, 25)

      {:ok, _view, html} = live(conn, ~p"/issue")

      assert html =~ "Eletrodo ECG adulto"
      refute html =~ "Cânula de Guedel"
    end

    test "picking from the shelf opens the same form as the search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      # "Separar", not "Adicionar": this screen takes goods out of stock, and a
      # row whose action read "add" said the opposite of what the screen does.
      html = view |> element("button", "Separar") |> render_click()

      assert html =~ "disponíveis aqui" or html =~ "Eletrodo ECG adulto"
      assert has_element?(view, "#issue-form")
    end

    # The whole reason the basket exists: nothing here is ever deleted, so a
    # line posted by mistake could only be undone by a correcting adjustment
    # filed forever.
    test "a line added by mistake is removed, not corrected", %{
      conn: conn,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("button", "Separar") |> render_click()
      view |> element("#issue-form") |> render_submit(%{"quantity" => "30"})

      # An icon now, so it is found by the name it carries for anyone who
      # cannot see it — which is the only reason an icon-only button is allowed
      # to be one.
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

      # One event, not two.
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

  # Only the "into box" select. The page has other selects — where the return
  # comes from and where it arrives — and those are legitimately preselected.
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

    # This screen used to print what the ledger expected *and* type it into the
    # field for you — on the one screen where the ledger is least worth
    # trusting, because after a mission it is a hypothesis. Counting with the
    # answer written in the box measures nothing.
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

    # The hazard the blank field created: "o que não voltou foi usado" is ticked
    # by default, so a blank line read as zero would write the whole mission off
    # as consumed with nobody having counted anything.
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

    # Every line used to land on "sem caixa", so somebody re-picked a box for
    # each of forty rows after every mission.
    test "preselects the warehouse box that already holds the product", %{
      conn: conn,
      warehouse: warehouse,
      warehouse_box: warehouse_box,
      warehouse_lot: warehouse_lot
    } do
      # The warehouse copy of this product lives in IR04, which makes IR04 the
      # box this return belongs in.
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
      # The 20 that stayed behind were written off as used.
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(0))
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(160))
    end

    # A return can name forty boxes and invent three of them. All three are
    # named before any of them exist — asking three times in a row is how the
    # third one gets waved through.
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
      # Nothing was written while the question was open.
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
