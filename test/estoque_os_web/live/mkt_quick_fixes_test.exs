defmodule EstoqueOSWeb.MktQuickFixesTest do
  @moduledoc """
  Three small things the marketing role tripped over: a total that sat under
  the wrong column, a box list with no way to search it, and two questions on
  the new-product form that a shirt can only ever answer one way.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  describe "the stock total" do
    setup %{conn: conn}, do: register_and_log_in_operator(%{conn: conn})

    setup do
      warehouse = location_fixture(%{name: "Estoque Principal"})
      product = product_fixture(%{name: "Compressa de gaze"})
      lot = lot_fixture(%{product_id: product.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              quantity: Decimal.new(10),
              unit_cost: Decimal.new("3.00")
            }
          ]
        })

      :ok
    end

    # The footer spans the columns before the quantity — product, lot, expiry,
    # flags, where. It spanned four, so every number under it sat one column to
    # the left of the column it totals.
    test "spans every column before the numbers it totals", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ ~s{colspan="5"}
      refute html =~ ~s{colspan="4"}
    end
  end

  describe "the box list" do
    setup %{conn: conn}, do: register_and_log_in_operator(%{conn: conn})

    setup do
      warehouse = location_fixture(%{name: "Estoque Principal"})
      office = location_fixture(%{name: "Escritório São Paulo"})

      box_fixture(%{code: "AN01", location_id: warehouse.id})
      box_fixture(%{code: "MK07", location_id: office.id})

      :ok
    end

    test "narrows by the code written on the box", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      found = view |> form("#box-search", %{"search" => "mk"}) |> render_change()

      assert text(found) =~ "MK07"
      refute text(found) =~ "AN01"
    end

    # Accents and case are what somebody standing in front of a shelf actually
    # types, and "escritorio" must find "Escritório".
    test "narrows by where the box is standing, accents aside", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      found = view |> form("#box-search", %{"search" => "escritorio"}) |> render_change()

      assert text(found) =~ "MK07"
      refute text(found) =~ "AN01"
    end

    # An empty table says one thing; a search that matched nothing says
    # another, and the first one used to say both.
    test "says nothing matched rather than nothing exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boxes")

      empty = view |> form("#box-search", %{"search" => "zzzz"}) |> render_change()

      assert text(empty) =~ "Nenhuma caixa corresponde"
      refute text(empty) =~ "Nenhuma caixa cadastrada"
    end
  end

  describe "the marketing manual entry" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    setup do
      %{warehouse: location_fixture(%{name: "Estoque Principal"})}
    end

    # The create form only appears once a search found nothing, which is the
    # moment somebody is about to add a product.
    defp searching(view) do
      view |> form("#search-form", %{"query" => "Camiseta Operação Sorriso G"}) |> render_change()
      view
    end

    test "does not ask whether a shirt is controlled or expires", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entry")

      html = view |> searching() |> element("form#new-product") |> render()

      refute html =~ ~s{name="controlled"}
      refute html =~ ~s{name="expiry_expected"}
      assert html =~ ~s{name="lot_expected"}
    end

    # The tick is not rendered, so the answer cannot come from the form — and
    # must not be believed when it arrives from a hand-made submission either.
    test "refuses a hand-made controlled shirt", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entry")

      view
      |> searching()
      |> element("form#new-product")
      |> render_submit(%{
        "name" => "Camiseta Operação Sorriso G",
        "stock_unit" => "UN",
        "controlled" => "true",
        "expiry_expected" => "true",
        "lot_expected" => "false"
      })

      product =
        EstoqueOS.Repo.get_by!(EstoqueOS.Catalog.Product, name: "Camiseta Operação Sorriso G")

      assert product.segment == "marketing"
      refute product.controlled
      refute product.expiry_expected
    end
  end
end
