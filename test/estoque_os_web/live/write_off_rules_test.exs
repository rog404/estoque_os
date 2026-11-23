defmodule EstoqueOSWeb.WriteOffRulesTest do
  @moduledoc """
  Where the goods went, which lot they came out of, and who may put a price on
  them. The destination is mandatory, the lot can be pinned (FEFO is a shrug for
  a shirt), and the price field follows the destination, not the product.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound}
  alias EstoqueOS.Inventory.{Transaction, TransactionEntry}
  alias EstoqueOS.Repo

  import Ecto.Query

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    shirt = product_fixture(%{name: "Camiseta Operação Sorriso G", segment: "marketing"})
    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})

    old = stock_in(shirt, warehouse, 40, "L-2025")
    new = stock_in(shirt, warehouse, 60, "L-2026")
    stock_in(gauze, warehouse, 200, "L-777")

    %{warehouse: warehouse, shirt: shirt, gauze: gauze, old: old, new: new}
  end

  defp stock_in(product, location, quantity, lot_number) do
    lot = lot_fixture(%{product_id: product.id, lot_number: lot_number})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: location.id, quantity: Decimal.new(quantity)}
        ]
      })

    lot
  end

  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  defp pick(view, product) do
    view |> element("#search-form") |> render_change(%{"query" => product.name})
    view |> element("button", product.name) |> render_click()
  end

  defp choose(view, destination) do
    view |> form("#destination-form", %{"destination" => destination}) |> render_change()
  end

  describe "the destination" do
    setup :register_and_log_in_operator

    test "has no blank option to fall through", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/issue")

      refute text(html) =~ "não informado"
      assert html =~ ~s{name="destination"}
      assert html =~ "required"
    end

    # `required` is presentation; the rule lives in the context.
    test "is refused by the context when it is missing", %{
      warehouse: warehouse,
      gauze: gauze
    } do
      assert {:error, :missing_destination} =
               Outbound.issue(gauze.id, 5, %{
                 location_id: warehouse.id,
                 user_id: actor_id()
               })

      assert Decimal.equal?(
               Inventory.balance(location_id: warehouse.id, product_id: gauze.id),
               Decimal.new(200)
             )
    end
  end

  describe "the marketing stock" do
    setup %{conn: conn}, do: register_and_log_in_as(%{conn: conn}, "marketing")

    test "is offered only the two places its goods go", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/issue")

      page = text(html)

      assert page =~ "Venda"
      assert page =~ "Doação"
      refute page =~ "PACU"
      refute page =~ "Centro cirúrgico"
      refute page =~ "Triagem"
    end

    # A shirt has no expiry, so FEFO sorts by lot id and the seller knows better.
    test "chooses which lot leaves", %{conn: conn, shirt: shirt, new: new, old: old} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      choose(view, "sale")
      html = pick(view, shirt)

      assert text(html) =~ "L-2025"
      assert text(html) =~ "L-2026"

      view
      |> element("#issue-form")
      |> render_submit(%{
        "quantity" => "5",
        "lot_id" => "#{new.id}",
        "sale_unit_price" => "39,90"
      })

      view |> element("#basket-form") |> render_submit(%{})

      assert Decimal.equal?(Inventory.balance(lot_id: new.id), Decimal.new(55))
      assert Decimal.equal?(Inventory.balance(lot_id: old.id), Decimal.new(40))
    end

    test "leaves the choice to FEFO when it is not made", %{conn: conn, shirt: shirt, old: old} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      choose(view, "sale")
      pick(view, shirt)

      view
      |> element("#issue-form")
      |> render_submit(%{"quantity" => "5", "lot_id" => "", "sale_unit_price" => "39,90"})

      view |> element("#basket-form") |> render_submit(%{})

      assert Decimal.equal?(Inventory.balance(lot_id: old.id), Decimal.new(35))
    end
  end

  describe "an admin" do
    setup :register_and_log_in_admin

    test "can sell, and the price is asked for and kept", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      choose(view, "sale")
      html = pick(view, gauze)

      assert text(html) =~ "Preço de venda"

      view
      |> element("#issue-form")
      |> render_submit(%{"quantity" => "10", "sale_unit_price" => "2,50"})

      view |> element("#basket-form") |> render_submit(%{})

      entry =
        Repo.one!(
          from e in TransactionEntry,
            join: t in assoc(e, :transaction),
            where: t.destination == "sale"
        )

      assert Decimal.equal?(entry.sale_unit_price, Decimal.new("2.50"))
      assert Decimal.equal?(entry.quantity, Decimal.new(-10))
    end

    # A price on a donation would be a number nobody paid.
    test "is not asked for a price on anything else", %{conn: conn, gauze: gauze} do
      {:ok, view, _html} = live(conn, ~p"/issue")

      choose(view, "donation")
      html = pick(view, gauze)

      refute text(html) =~ "Preço de venda"
    end

    test "keeps the whole list of destinations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/issue")

      page = text(html)

      assert page =~ "PACU"
      assert page =~ "Descarte"
      assert page =~ "Venda"
    end
  end

  describe "the movement" do
    setup :register_and_log_in_operator

    # The screen opens on surgical, so a marketing line needs the marketing filter.
    test "records the lot the operator pinned", %{conn: conn, shirt: shirt, new: new} do
      {:ok, view, _html} = live(conn, ~p"/issue?segment=marketing")

      choose(view, "donation")
      pick(view, shirt)

      view
      |> element("#issue-form")
      |> render_submit(%{"quantity" => "3", "lot_id" => "#{new.id}"})

      view |> element("#basket-form") |> render_submit(%{})

      transaction = Repo.one!(from t in Transaction, where: t.type == "manual_out")
      entry = Repo.one!(from e in TransactionEntry, where: e.transaction_id == ^transaction.id)

      assert entry.lot_id == new.id
      assert transaction.destination == "donation"
    end
  end
end
