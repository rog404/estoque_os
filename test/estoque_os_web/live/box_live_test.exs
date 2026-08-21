defmodule EstoqueOSWeb.BoxLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Repo

  # Moving a box, creating one and stamping a count are all writes. These passed
  # as a viewer only because the events were unguarded; the role they always
  # required is operator.
  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    transit = location_fixture(%{name: "Trânsito", kind: "transit"})
    annex = location_fixture(%{name: "Anexo SP", kind: "warehouse"})

    box = box_fixture(%{code: "BL01", location_id: warehouse.id})
    product = product_fixture(%{name: "Eletrodo ECG adulto"})
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            box_id: box.id,
            location_id: warehouse.id,
            quantity: Decimal.new(300)
          }
        ]
      })

    %{
      warehouse: warehouse,
      mission: mission,
      transit: transit,
      annex: annex,
      box: box,
      lot: lot
    }
  end

  describe "index" do
    test "shows where each box is and what it holds", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/boxes")

      assert html =~ "BL01"
      assert html =~ "Estoque Principal"
      assert html =~ "300"
      assert html =~ "nunca contada"
    end

    test "moves a box with its contents", %{conn: conn, box: box, annex: annex} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      html =
        view
        |> element("#move-#{box.id}")
        |> render_submit(%{"location_id" => annex.id})

      assert html =~ "Caixa BL01 movida para Anexo SP"
      assert Decimal.equal?(Inventory.balance(location_id: annex.id), Decimal.new(300))
    end

    # A mission and transit are not on the menu here: arriving at either is the
    # moment the movement acquires a trip, and only the load-out asks which.
    test "does not offer a mission or transit as somewhere to carry a box", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/boxes")

      move_selects = Regex.scan(~r{<select[^>]*Mover[^>]*>.*?</select>}s, html)

      assert move_selects != []

      for [select] <- move_selects do
        refute select =~ "Missão Tefé"
        refute select =~ "Trânsito"
        assert select =~ "Anexo SP"
      end
    end

    # And the rule lives in the context, so a hand-crafted event cannot get past
    # a select that simply does not offer the option.
    test "refuses a mission even when the event asks for one", %{
      conn: conn,
      box: box,
      mission: mission
    } do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      html =
        view
        |> element("#move-#{box.id}")
        |> render_submit(%{"location_id" => mission.id})

      assert html =~ "derrubada de carga"
      assert Decimal.equal?(Inventory.balance(location_id: mission.id), Decimal.new(0))
    end

    test "creates a box", %{conn: conn, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      html =
        view
        |> element("#new-box")
        |> render_submit(%{"code" => "jp04", "location_id" => warehouse.id})

      assert html =~ "Caixa JP04 criada"
    end

    test "refuses a code already in use", %{conn: conn, warehouse: warehouse} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      html =
        view
        |> element("#new-box")
        |> render_submit(%{"code" => "BL01", "location_id" => warehouse.id})

      assert html =~ "código que ainda não esteja em uso"
    end
  end

  describe "show" do
    test "lists what the box is presumed to hold", %{conn: conn, box: box} do
      {:ok, _view, html} = live(conn, ~p"/boxes/#{box}")

      assert html =~ "Caixa BL01"
      assert html =~ "Eletrodo ECG adulto"
      assert html =~ "300"
    end

    # Counting a box and saying it was counted are different acts, and this
    # screen only ever offered the second.
    test "leads to the blind count of this box", %{conn: conn, box: box} do
      {:ok, _view, html} = live(conn, ~p"/boxes/#{box}")

      assert html =~ ~s(href="/audit/#{box.id}")
    end

    test "moves the box from its own page", %{conn: conn, box: box, annex: annex} do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      html = view |> element("#move-form") |> render_submit(%{"location_id" => annex.id})

      assert html =~ "movida para Anexo SP"
      assert Repo.reload!(box).location_id == annex.id
    end

    test "will not send the box to a mission from here either", %{
      conn: conn,
      box: box,
      mission: mission
    } do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      html = view |> element("#move-form") |> render_submit(%{"location_id" => mission.id})

      assert html =~ "derrubada de carga"
      assert Repo.reload!(box).location_id != mission.id
    end

    test "moves part of a lot into another box in the same room", %{
      conn: conn,
      box: box,
      lot: lot,
      warehouse: warehouse
    } do
      other = box_fixture(%{code: "BL02", location_id: warehouse.id})

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      html =
        view
        |> element("#rebox-#{lot.id}")
        |> render_submit(%{"quantity" => "120", "box_code" => other.code})

      assert html =~ "movida(s) para BL02" or html =~ "120"

      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(180))
      assert Decimal.equal?(Inventory.balance(box_id: other.id), Decimal.new(120))
      # The goods never left the room.
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(300))
    end

    test "will not lend what the box does not hold", %{
      conn: conn,
      box: box,
      lot: lot,
      warehouse: warehouse
    } do
      other = box_fixture(%{code: "BL03", location_id: warehouse.id})

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      html =
        view
        |> element("#rebox-#{lot.id}")
        |> render_submit(%{"quantity" => "9000", "box_code" => other.code})

      assert html =~ "só tem 300"
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(300))
    end

    # The same question the conference and manual entry ask. A code one
    # character wrong makes a box that exists, is empty, and is never opened
    # again.
    test "an unknown box code is not created until it is confirmed", %{
      conn: conn,
      box: box,
      lot: lot,
      warehouse: warehouse
    } do
      # The re-box column only exists when the room has somewhere else to put
      # things.
      box_fixture(%{code: "BL08", location_id: warehouse.id})

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      html =
        view
        |> element("#rebox-#{lot.id}")
        |> render_submit(%{"quantity" => "10", "box_code" => "BL0O"})

      assert html =~ "Criar a caixa BL0O"
      refute Enum.any?(Locations.list_boxes(warehouse.id), &(&1.code == "BL0O"))
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(300))

      # Declining leaves the goods exactly where they were.
      view |> element("#cancel-new-box") |> render_click()
      refute Enum.any?(Locations.list_boxes(warehouse.id), &(&1.code == "BL0O"))
    end

    test "confirming creates the box and makes the move that was waiting", %{
      conn: conn,
      box: box,
      lot: lot,
      warehouse: warehouse
    } do
      box_fixture(%{code: "BL09", location_id: warehouse.id})

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      view
      |> element("#rebox-#{lot.id}")
      |> render_submit(%{"quantity" => "10", "box_code" => "BL77"})

      view |> element("#confirm-new-box") |> render_click()

      created = Enum.find(Locations.list_boxes(warehouse.id), &(&1.code == "BL77"))

      assert created
      assert Decimal.equal?(Inventory.balance(box_id: created.id), Decimal.new(10))
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(290))
    end

    # Re-boxing says nothing about whether the count was right.
    test "does not stamp either box as verified", %{
      conn: conn,
      box: box,
      lot: lot,
      warehouse: warehouse
    } do
      other = box_fixture(%{code: "BL05", location_id: warehouse.id})

      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      view
      |> element("#rebox-#{lot.id}")
      |> render_submit(%{"quantity" => "10", "box_code" => other.code})

      refute Repo.reload!(box).last_verified_at
      refute Repo.reload!(other).last_verified_at
    end

    test "marking a box as counted does not touch quantities", %{
      conn: conn,
      box: box,
      lot: lot
    } do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box}")

      html = view |> element("button", "Marcar como contada") |> render_click()

      assert html =~ "Caixa marcada como contada hoje"
      assert Repo.reload!(box).last_verified_at
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id), Decimal.new(300))
    end
  end

  describe "loose stock" do
    setup %{warehouse: warehouse} do
      product = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
      lot = lot_fixture(%{product_id: product.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "donation_in",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, box_id: nil, location_id: warehouse.id, quantity: Decimal.new(40)}
          ]
        })

      %{loose_lot: lot}
    end

    # The question this answers had no answer: `rebox` needs a box to take the
    # goods *out* of, and loose stock is exactly the stock with none. Goods that
    # arrived through a manual entry with the box left blank sat where no
    # load-out would carry them and no screen would move them.
    test "is listed on the box screen, waiting for a box", %{conn: conn, box: box} do
      {:ok, _view, html} = live(conn, ~p"/boxes/#{box.id}")

      assert html =~ "Solto aqui, sem caixa"
      assert html =~ "Compressa de gaze 7,5x7,5"
      assert html =~ "Guardar em BL01"
    end

    test "goes into the box, and the location's balance does not move", %{
      conn: conn,
      box: box,
      warehouse: warehouse,
      loose_lot: lot
    } do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      at_location = Inventory.balance(lot_id: lot.id, location_id: warehouse.id)

      html =
        view
        |> element("#stow-#{lot.id}")
        |> render_submit(%{"quantity" => "40"})

      assert html =~ "Guardado em BL01"

      # Nothing left the room: only where inside it the goods sit changed.
      assert Decimal.equal?(
               Inventory.balance(lot_id: lot.id, location_id: warehouse.id),
               at_location
             )

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, box_id: box.id), Decimal.new(40))

      assert Decimal.equal?(
               Inventory.balance(lot_id: lot.id, location_id: warehouse.id, box_id: nil),
               Decimal.new(0)
             )
    end

    test "part of it can go, and the rest stays loose", %{conn: conn, box: box, loose_lot: lot} do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      view |> element("#stow-#{lot.id}") |> render_submit(%{"quantity" => "15"})

      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, box_id: box.id), Decimal.new(15))

      assert Decimal.equal?(
               Inventory.balance(lot_id: lot.id, box_id: nil),
               Decimal.new(25)
             )
    end

    test "more than is loose is refused", %{conn: conn, box: box, loose_lot: lot} do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      html = view |> element("#stow-#{lot.id}") |> render_submit(%{"quantity" => "999"})

      assert html =~ "40 solto"
      assert Decimal.equal?(Inventory.balance(lot_id: lot.id, box_id: box.id), Decimal.new(0))
    end

    # Putting things into a box says nothing about whether the count in it was
    # right, and stamping it would launder a presumption into a verification.
    test "does not mark the box as counted", %{conn: conn, box: box, loose_lot: lot} do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      view |> element("#stow-#{lot.id}") |> render_submit(%{"quantity" => "40"})

      assert is_nil(Locations.get_box!(box.id).last_verified_at)
    end
  end

  describe "locations" do
    test "lists the places stock can be, with what they hold", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/locations")

      assert html =~ "Estoque Principal"
      assert html =~ "depósito"
      assert html =~ "Trânsito"
      assert html =~ "em trânsito"
      assert html =~ "300"
    end

    test "creates a mission site", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/locations")

      html =
        view
        |> element("#new-location")
        |> render_submit(%{"name" => "Missão Coari", "kind" => "mission_site"})

      assert html =~ "Local Missão Coari criado"
      assert html =~ "local de missão"
    end
  end
end
