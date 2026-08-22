defmodule EstoqueOSWeb.HomeSegmentTest do
  @moduledoc """
  The overview, once for each stock.

  Surgical supplies and marketing material share a warehouse and almost nothing
  else: a shirt about to expire is not a mission problem, and a coordinator
  reading one number for both was reading neither. Whoever holds both stocks
  gets tabs; whoever holds one gets their own overview and no choice at all.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
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

    # The screen opens on the stock this role works in — surgical, for the
    # supplies coordinator — and the whole operation is the first tab.
    test "opens on its own stock and is offered both plus everything", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert text(html) =~ "Compressa de gaze"
      refute text(html) =~ "Camiseta"
      assert html =~ ~s{href="/?segment=all"}
      assert html =~ ~s{href="/?segment=marketing"}
      assert html =~ ~s{href="/?segment=medical"}
    end

    test "reads both stocks at once on the first tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?segment=all")

      assert text(html) =~ "Compressa de gaze"
      assert text(html) =~ "Camiseta"
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

    # The pace panels belong to the stock that is sold. On the surgical
    # overview they would be three more things to scroll past on a screen meant
    # to be read standing up, answering a question nobody plans a mission by.
    test "only the marketing tab reads a selling pace", %{conn: conn} do
      {:ok, _view, medical} = live(conn, ~p"/?segment=medical")
      {:ok, _view, marketing} = live(conn, ~p"/?segment=marketing")

      assert text(marketing) =~ "Mais vendidos"
      assert text(marketing) =~ "Hora de repor"
      refute text(medical) =~ "Mais vendidos"
      assert text(medical) =~ "Abaixo do mínimo da missão"
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

  describe "the marketing overview" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    setup %{warehouse: warehouse, shirt: shirt} do
      lot = lot_fixture(%{product_id: shirt.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(100)}
          ]
        })

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "manual_out",
          destination: "sale",
          user_id: actor_id(),
          entries: [
            %{
              lot_id: lot.id,
              location_id: warehouse.id,
              quantity: Decimal.new(-30),
              sale_unit_price: Decimal.new("35.00")
            }
          ]
        })

      :ok
    end

    test "speaks about selling rather than about missions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      page = text(html)

      assert page =~ "Hora de repor"
      refute page =~ "Abaixo do mínimo da missão"
      assert page =~ "Produtos à venda"
      refute page =~ "Catálogo"
    end

    # A shirt has no expiry date, so "nada vencendo" is not news on this tab —
    # it is an empty panel sitting above the two panels this person opens the
    # page for. A printed item that does carry a date still shows up.
    test "the expiry panel only shows up when something is expiring", %{
      conn: conn,
      shirt: shirt
    } do
      {:ok, _view, close} = live(conn, ~p"/")

      assert text(close) =~ "Vencendo em breve"

      EstoqueOS.Repo.update_all(
        from(l in EstoqueOS.Inventory.Lot, where: l.product_id == ^shirt.id),
        set: [expires_on: nil]
      )

      {:ok, _view, far} = live(conn, ~p"/")

      refute text(far) =~ "Vencendo em breve"
    end

    test "says what left, how long it lasts and what did not move", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      page = text(html)

      assert page =~ "Mais vendidos"
      assert page =~ "Acaba primeiro"
      assert page =~ "Parado"
      assert page =~ "Vendido em 90 dias"
    end
  end

  describe "the marketing role" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    test "opens on its own stock", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert text(html) =~ "Camiseta"
      refute text(html) =~ "Compressa de gaze"
    end

    # The stock is a filter now, and the address is one way to change it: the
    # marketing coordinator may look at the surgical shelf, they just do not
    # land on it.
    test "can ask for the other one in the address", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?segment=medical")

      assert text(html) =~ "Compressa de gaze"
    end
  end

  describe "the auditor" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "auditor")

    test "reads the whole operation and gets the tabs too", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?segment=all")

      assert text(html) =~ "Compressa de gaze"
      assert text(html) =~ "Camiseta"
      assert html =~ ~s{href="/?segment=marketing"}
    end
  end
end
