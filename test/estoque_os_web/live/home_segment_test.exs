defmodule EstoqueOSWeb.HomeSegmentTest do
  @moduledoc """
  The overview, once for each stock.

  Surgical supplies and marketing material share a warehouse and almost nothing
  else: a shirt about to expire is not a mission problem, and a coordinator
  reading one number for both was reading neither. Whoever holds both stocks
  gets tabs; whoever holds one gets their own overview and no choice at all.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    shirt = product_fixture(%{name: "Camiseta Operação Sorriso", segment: "marketing"})

    expiring(gauze, warehouse)
    expiring(shirt, warehouse)

    %{warehouse: warehouse, gauze: gauze, shirt: shirt}
  end

  # Both land in the "expiring soon" panel, which is the one panel that names a
  # product on this screen — so it is the one that can say which stock is being
  # looked at.
  defp expiring(product, location) do
    lot =
      lot_fixture(%{product_id: product.id, expires_on: Date.add(Date.utc_today(), 10)})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: location.id, quantity: Decimal.new(30)}
        ]
      })
  end

  # `refute html =~ "..."` matches markup as happily as text, so anything
  # asserting a product is *absent* strips the tags first.
  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  describe "a role that holds both stocks" do
    setup %{conn: conn}, do: register_and_log_in_operator(%{conn: conn})

    test "opens on everything and is offered both", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert text(html) =~ "Compressa de gaze"
      assert text(html) =~ "Camiseta"
      assert html =~ ~s{href="/?segment=marketing"}
      assert html =~ ~s{href="/?segment=medical"}
    end

    test "the surgical tab leaves the marketing stock out", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?segment=medical")

      assert text(html) =~ "Compressa de gaze"
      refute text(html) =~ "Camiseta"
    end

    test "the marketing tab leaves the surgical stock out", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?segment=marketing")

      assert text(html) =~ "Camiseta"
      refute text(html) =~ "Compressa de gaze"
    end

    # The tab is a patch, so the panels have to answer the new address without
    # a full mount: a tab that only worked on reload is the same bug as no tab.
    test "switching tab reloads the panels in place", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      switched = view |> element(~s{a[href="/?segment=marketing"]}) |> render_click()

      assert text(switched) =~ "Camiseta"
      refute text(switched) =~ "Compressa de gaze"
    end

    # Boxes and disputed counts belong to no segment, so the marketing tab
    # hides those panels rather than showing them empty — the same rule the
    # marketing role has always had.
    test "the marketing tab drops the panels that are about boxes", %{conn: conn} do
      {:ok, _view, medical} = live(conn, ~p"/?segment=medical")
      {:ok, _view, marketing} = live(conn, ~p"/?segment=marketing")

      assert text(medical) =~ "Caixas para recontar"
      refute text(marketing) =~ "Caixas para recontar"
    end
  end

  describe "a role that holds one stock" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    test "is never offered the other one", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert text(html) =~ "Camiseta"
      refute text(html) =~ "Compressa de gaze"
      refute html =~ "segment=medical"
    end

    # The address is not a way in. `Scope.segment/2` gives the marketing role
    # their own segment whatever arrives, so asking for the surgical overview
    # returns the marketing one rather than an empty one.
    test "cannot ask for the other one in the address", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?segment=medical")

      assert text(html) =~ "Camiseta"
      refute text(html) =~ "Compressa de gaze"
    end
  end

  describe "the auditor" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "auditor")

    test "reads the whole operation and gets the tabs too", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert text(html) =~ "Compressa de gaze"
      assert text(html) =~ "Camiseta"
      assert html =~ ~s{href="/?segment=marketing"}
    end
  end
end
