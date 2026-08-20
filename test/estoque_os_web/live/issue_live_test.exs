defmodule EstoqueOSWeb.IssueLiveTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    product = product_fixture(%{name: "Avental EG"})
    lone = product_fixture(%{name: "Gaze embalada"})

    lone_lot = lot_fixture(%{product_id: lone.id, expires_on: ~D[2027-01-31]})
    stock_in(lone_lot, warehouse, 30)

    %{warehouse: warehouse, product: product, lone: lone}
  end

  # The quantity input on its own. Asserting against the whole page would let
  # the search field's value satisfy the assertion.
  defp quantity_field(html) do
    case Regex.run(~r{<input[^>]*name="quantity"[^>]*>}, html) do
      [field] -> field
      nil -> flunk("no quantity field on the page")
    end
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

  describe "a product in a single place" do
    test "offers no box choice", %{conn: conn, lone: lone} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => lone.name})
      html = view |> element("button", lone.name) |> render_click()

      refute html =~ "Tirar de"
    end
  end

  describe "a product split across boxes" do
    setup %{warehouse: warehouse, product: product} do
      near = box_fixture(%{code: "AA01", location_id: warehouse.id})
      far = box_fixture(%{code: "BB02", location_id: warehouse.id})

      near_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2026-09-30]})
      far_lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2028-06-30]})

      stock_in(near_lot, warehouse, 10, box_id: near.id)
      stock_in(far_lot, warehouse, 10, box_id: far.id)

      %{near: near, far: far, near_lot: near_lot, far_lot: far_lot}
    end

    test "lists the boxes and recommends the one expiring soonest", %{
      conn: conn,
      product: product,
      near: near,
      far: far
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      html = view |> element("button", product.name) |> render_click()

      assert html =~ "Tirar de"
      assert html =~ near.code
      assert html =~ far.code
      # The recommendation names the box expiring soonest.
      assert html =~ "recomendado: #{near.code}"
    end

    test "left blank, still picks FEFO across every box", %{
      conn: conn,
      product: product,
      near_lot: near_lot,
      far_lot: far_lot
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      view |> element("#issue-form") |> render_submit(%{"quantity" => "5"})
      view |> element("#basket-form") |> render_submit(%{})

      # 5 came from the box expiring soonest, the other box untouched.
      assert Decimal.equal?(Inventory.balance(lot_id: near_lot.id), Decimal.new(5))
      assert Decimal.equal?(Inventory.balance(lot_id: far_lot.id), Decimal.new(10))
    end

    test "choosing a specific box draws only from it, even if it is not the soonest", %{
      conn: conn,
      product: product,
      far: far,
      near_lot: near_lot,
      far_lot: far_lot
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      html =
        view
        |> element("#issue-form")
        |> render_submit(%{"quantity" => "4", "box_id" => "#{far.id}"})

      assert html =~ far.code

      view |> element("#basket-form") |> render_submit(%{})

      assert Decimal.equal?(Inventory.balance(lot_id: far_lot.id), Decimal.new(6))
      assert Decimal.equal?(Inventory.balance(lot_id: near_lot.id), Decimal.new(10))
    end

    test "the preview shows what will come out, following quantity and box", %{
      conn: conn,
      product: product,
      near: near
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      html =
        view
        |> element("#issue-form")
        |> render_change(%{"quantity" => "3", "box_id" => ""})

      assert html =~ "Vai sair de"
      assert html =~ near.code
    end

    # Reported as a bug, and it read as one: the operator typed the quantity,
    # the FEFO preview appeared, and the field they were typing into went blank.
    # `phx-change` repaints this form on every keystroke, and an input rendered
    # without a value is repainted empty.
    test "the quantity typed survives the repaint the preview causes", %{
      conn: conn,
      product: product
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      html =
        view
        |> element("#issue-form")
        |> render_change(%{"quantity" => "3", "box_id" => ""})

      assert quantity_field(html) =~ ~s(value="3")
    end

    # The other half of the same report. What appears on its own does not get to
    # move what the thumb is already aimed at, so the preview is rendered after
    # the field and its buttons, never above them.
    test "the preview is drawn below the quantity, not above it", %{
      conn: conn,
      product: product
    } do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      html =
        view
        |> element("#issue-form")
        |> render_change(%{"quantity" => "3", "box_id" => ""})

      [{field, _}] = Regex.run(~r/name="quantity"/, html, return: :index)
      [{preview, _}] = Regex.run(~r/Vai sair de/, html, return: :index)

      assert field < preview
    end

    # Empty again once the line is in the basket, so the next product does not
    # arrive holding the last one's number.
    test "the quantity is cleared after the line is added", %{conn: conn, product: product} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()
      view |> element("#issue-form") |> render_change(%{"quantity" => "3", "box_id" => ""})
      view |> element("#issue-form") |> render_submit(%{"quantity" => "3", "box_id" => ""})

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      html = view |> element("button", product.name) |> render_click()

      assert quantity_field(html) =~ ~s(value="")
    end

    test "refuses a specific box that cannot cover the quantity, even though another box could",
         %{conn: conn, product: product, near: near} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      view |> element("#search-form") |> render_change(%{"query" => product.name})
      view |> element("button", product.name) |> render_click()

      view
      |> element("#issue-form")
      |> render_submit(%{"quantity" => "20", "box_id" => "#{near.id}"})

      html = view |> element("#basket-form") |> render_submit(%{})

      assert html =~ "Não há o bastante aqui"
    end
  end
end
