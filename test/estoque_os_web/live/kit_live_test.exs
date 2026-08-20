defmodule EstoqueOSWeb.KitLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Kits}
  alias EstoqueOS.Inventory.Locations

  # Packing and consuming a kit move stock. These passed as a viewer only because
  # the events were unguarded.
  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    box = box_fixture(%{code: "KIT01", location_id: warehouse.id})

    gown = product_fixture(%{name: "Avental EG"})
    pen = product_fixture(%{name: "Caneta de eletrocautério"})

    {:ok, kit} =
      Kits.create_kit(%{
        name: "Kit Paciente",
        items: [
          %{description: "Avental EG", quantity: Decimal.new(4), product_id: gown.id},
          %{description: "Caneta de eletrocautério", quantity: Decimal.new(1), product_id: pen.id}
        ]
      })

    for {product, quantity} <- [{gown, 40}, {pen, 6}] do
      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot_fixture(%{product_id: product.id}).id,
              location_id: warehouse.id,
              quantity: Decimal.new(quantity)
            }
          ]
        })
    end

    %{warehouse: warehouse, box: box, gown: gown, pen: pen, kit: Kits.get_kit!(kit.id)}
  end

  describe "index" do
    test "shows how many kits the stock covers and what holds it back", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/kits")

      assert html =~ "Kit Paciente"
      assert html =~ "kits possíveis"
      # 6 pens cap it at 6 kits.
      assert html =~ "6"
      assert html =~ "limitado por: Caneta de eletrocautério"
    end
  end

  describe "show" do
    test "lists components with what the stock covers", %{conn: conn, kit: kit} do
      {:ok, _view, html} = live(conn, ~p"/kits/#{kit}")

      assert html =~ "Avental EG"
      assert html =~ "40"
      assert html =~ "10"
    end

    test "assembling converts the components into the kit's own product", %{
      conn: conn,
      kit: kit,
      box: box,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      view |> element("#review-form") |> render_submit(%{"quantity" => "2"})

      html =
        view
        |> element("#assemble-form")
        |> render_submit(%{"box_id" => "#{box.id}"})

      assert html =~ "Kits montados"
      # 2 kits: the box holds 2 of the kit's own product now.
      assert Decimal.equal?(
               Inventory.balance(box_id: box.id, product_id: kit.product.id),
               Decimal.new(2)
             )

      # 8 gowns and 2 pens left stock for good.
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(38))
    end

    # Packing invented a box from whatever was in the field. A code one
    # character wrong makes a box that exists, is empty, and is never opened.
    test "an unknown box code is not created until it is confirmed", %{
      conn: conn,
      kit: kit,
      warehouse: warehouse
    } do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      view |> element("#review-form") |> render_submit(%{"quantity" => "1"})

      html =
        view
        |> element("#assemble-form")
        |> render_submit(%{"box_code" => "KT0O"})

      assert html =~ "Criar a caixa KT0O"
      refute Enum.any?(Locations.list_boxes(warehouse.id), &(&1.code == "KT0O"))
      # Nothing was packed while the question was open.
      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(46))

      view |> element("#confirm-new-box") |> render_click()

      created = Enum.find(Locations.list_boxes(warehouse.id), &(&1.code == "KT0O"))
      assert created
      assert Decimal.equal?(Inventory.balance(box_id: created.id), Decimal.new(1))
    end

    test "names the component that runs short", %{conn: conn, kit: kit, box: box} do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      view |> element("#review-form") |> render_submit(%{"quantity" => "10"})

      html =
        view
        |> element("#assemble-form")
        |> render_submit(%{"box_id" => "#{box.id}"})

      assert html =~ "Falta Caneta de eletrocautério"
      assert html =~ "4 em falta"
    end

    test "refuses a kit whose components are not linked", %{conn: conn, warehouse: warehouse} do
      {:ok, unresolved} =
        Kits.create_kit(%{
          name: "Kit Enfermagem",
          items: [%{description: "Atadura elástica", quantity: Decimal.new(2)}]
        })

      {:ok, view, html} = live(conn, ~p"/kits/#{unresolved}")

      assert html =~ "não estão ligados a um produto do catálogo"

      view |> element("#review-form") |> render_submit(%{"quantity" => "1"})
      html = view |> element("#assemble-form") |> render_submit(%{})

      assert html =~ "1 componente(s) ainda precisam de um produto"

      assert Decimal.equal?(Inventory.balance(location_id: warehouse.id), Decimal.new(46))
    end
  end

  describe "review before packing" do
    test "checking a quantity lists what it needs and where it is", %{
      conn: conn,
      kit: kit,
      box: box,
      pen: pen
    } do
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot_fixture(%{product_id: pen.id}).id,
            location_id: box.location_id,
            box_id: box.id,
            quantity: Decimal.new(3)
          }
        ]
      })

      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      html = view |> element("#review-form") |> render_submit(%{"quantity" => "2"})

      assert html =~ "o que precisa"
      # 2 kits need 8 gowns and 2 pens.
      assert html =~ "8"
      assert html =~ box.code
      refute html =~ "id=\"review-form\""
    end

    test "an unmet need is called out", %{conn: conn, kit: kit} do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      html = view |> element("#review-form") |> render_submit(%{"quantity" => "10"})

      assert html =~ "text-error"
    end

    test "changing the quantity goes back to the plain form", %{conn: conn, kit: kit} do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      view |> element("#review-form") |> render_submit(%{"quantity" => "2"})
      html = view |> element("button[phx-click=review_again]") |> render_click()

      refute html =~ "o que precisa"
      assert html =~ "review-form"
    end

    test "switching location drops a pending review", %{conn: conn, kit: kit} do
      other = location_fixture(%{name: "Outro local", kind: "warehouse"})
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit}")

      view |> element("#review-form") |> render_submit(%{"quantity" => "2"})

      html =
        view
        |> element("#location-form")
        |> render_change(%{"location_id" => "#{other.id}"})

      refute html =~ "o que precisa"
    end
  end

  describe "editing the recipe" do
    test "creates a kit and lands on its screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/kits")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> form("#new-kit", %{"name" => "Kit Recuperação"}) |> render_submit()

      {:ok, _view, html} = live(conn, to)
      assert html =~ "Kit Recuperação"
      assert html =~ "ainda não tem componentes"
    end

    # The product *is* the component: it is named once, and the line takes the
    # catalog's own wording rather than something retyped beside it.
    test "adds a component by naming a catalog product", %{conn: conn, kit: kit} do
      drape = product_fixture(%{name: "Campo cirúrgico 50x50"})

      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      html =
        view
        |> form("#add-item", %{"product_name" => drape.name, "quantity" => "2"})
        |> render_submit()

      assert html =~ drape.name

      item = Enum.find(Kits.get_kit!(kit.id).items, &(&1.product_id == drape.id))
      assert item.description == drape.name
      assert Decimal.equal?(item.quantity, Decimal.new(2))
    end

    # Two lines for one product would have `availability/2` count the same stock
    # against each of them, so a kit needing 4 and 2 of a thing covers neither.
    test "refuses a product the recipe already lists", %{conn: conn, kit: kit, gown: gown} do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      html =
        view
        |> form("#add-item", %{"product_name" => gown.name, "quantity" => "2"})
        |> render_submit()

      assert html =~ "já está neste kit"
      assert Enum.count(Kits.get_kit!(kit.id).items, &(&1.product_id == gown.id)) == 1
    end

    # A recipe made of free text cannot say how many kits the stock covers,
    # cannot be packed and cannot be consumed.
    test "refuses a component the catalog has never heard of", %{conn: conn, kit: kit} do
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      html =
        view
        |> form("#add-item", %{"product_name" => "Campo cirúrgico", "quantity" => "2"})
        |> render_submit()

      assert html =~ "não está no catálogo"
      refute Enum.any?(Kits.get_kit!(kit.id).items, &(&1.description == "Campo cirúrgico"))
    end

    test "changes how many go in each kit", %{conn: conn, kit: kit} do
      item = hd(Kits.get_kit!(kit.id).items)
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      view
      |> element(~s(form[phx-value-id="#{item.id}"]))
      |> render_submit(%{"quantity" => "9"})

      updated = Enum.find(Kits.get_kit!(kit.id).items, &(&1.id == item.id))
      assert Decimal.equal?(updated.quantity, Decimal.new(9))
    end

    test "refuses a quantity of zero", %{conn: conn, kit: kit} do
      item = hd(Kits.get_kit!(kit.id).items)
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      html =
        view
        |> element(~s(form[phx-value-id="#{item.id}"]))
        |> render_submit(%{"quantity" => "0"})

      assert html =~ "quantity"
      updated = Enum.find(Kits.get_kit!(kit.id).items, &(&1.id == item.id))
      refute Decimal.equal?(updated.quantity, Decimal.new(0))
    end

    test "removes a component", %{conn: conn, kit: kit} do
      item = hd(Kits.get_kit!(kit.id).items)
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      view |> element("#remove-form-#{item.id}") |> render_submit()

      refute Enum.any?(Kits.get_kit!(kit.id).items, &(&1.id == item.id))
    end

    # An operator viewing Kit A must not be able to reach into Kit B by typing
    # a different id into the same event — the id in the event params comes
    # straight from the client, and Kit B's own page was never opened.
    test "an item id from another kit is refused, not mutated", %{conn: conn, kit: kit} do
      other_product = product_fixture(%{name: "Máscara cirúrgica"})

      {:ok, other_kit} =
        Kits.create_kit(%{
          name: "Kit B",
          items: [
            %{
              description: other_product.name,
              quantity: Decimal.new(3),
              product_id: other_product.id
            }
          ]
        })

      foreign_item = hd(Kits.get_kit!(other_kit.id).items)
      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      html =
        view
        |> render_hook("update_item", %{"id" => "#{foreign_item.id}", "quantity" => "1"})

      assert html =~ "não faz parte deste kit"

      untouched = Enum.find(Kits.get_kit!(other_kit.id).items, &(&1.id == foreign_item.id))
      assert Decimal.equal?(untouched.quantity, Decimal.new(3))

      html = view |> render_hook("remove_item", %{"item_id" => "#{foreign_item.id}"})
      assert html =~ "não faz parte deste kit"

      assert Enum.any?(Kits.get_kit!(other_kit.id).items, &(&1.id == foreign_item.id))
    end
  end

  describe "editing the recipe as logistics" do
    setup :register_and_log_in_logistics

    # Logistics packs and counts stock; changing what a kit is *made of* is a
    # planning decision reserved for admin/manager, same split as the minimum
    # on ProductLive.Show.
    test "cannot add, change, or remove a recipe component", %{conn: conn, kit: kit} do
      drape = product_fixture(%{name: "Campo cirúrgico 50x50"})
      item = hd(Kits.get_kit!(kit.id).items)

      {:ok, view, _html} = live(conn, ~p"/kits/#{kit.id}")

      view
      |> render_hook("add_item", %{"product_name" => drape.name, "quantity" => "2"})

      refute Enum.any?(Kits.get_kit!(kit.id).items, &(&1.product_id == drape.id))

      view |> render_hook("update_item", %{"id" => "#{item.id}", "quantity" => "9"})
      updated = Enum.find(Kits.get_kit!(kit.id).items, &(&1.id == item.id))
      refute Decimal.equal?(updated.quantity, Decimal.new(9))

      view |> render_hook("remove_item", %{"item_id" => "#{item.id}"})
      assert Enum.any?(Kits.get_kit!(kit.id).items, &(&1.id == item.id))
    end
  end
end
