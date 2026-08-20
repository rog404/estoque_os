defmodule EstoqueOSWeb.ManualEntryTest do
  @moduledoc """
  Donated goods are real stock with no document and no price. The point of these
  tests is the second half: the ledger records NO value, while the screen and the
  certificate show R$ 0,01. A symbolic centavo written into the ledger would drag
  average cost and stock value toward a number nobody paid.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Lot
  alias EstoqueOS.Repo

  setup :register_and_log_in_operator

  setup do
    %{
      warehouse: location_fixture(%{name: "Estoque Principal"}),
      toy: product_fixture(%{name: "Ursinho de pelúcia"})
    }
  end

  defp enter(view, params) do
    view |> form("#entry-form", params) |> render_submit()
  end

  defp pick(conn, toy) do
    {:ok, view, _html} = live(conn, ~p"/entry")
    render_change(element(view, "#search-form"), %{"query" => "Ursinho"})
    render_click(element(view, "button[phx-value-product='#{toy.id}']"))
    view
  end

  test "takes donated goods into stock with no value on record", %{conn: conn, toy: toy} do
    view = pick(conn, toy)

    html = enter(view, %{"quantity" => "12", "notes" => "Doado por uma escola"})

    assert html =~ "Ursinho de pelúcia"
    assert Decimal.equal?(Inventory.balance(product_id: toy.id), Decimal.new(12))

    entry =
      Repo.one!(
        from e in EstoqueOS.Inventory.TransactionEntry,
          join: t in assoc(e, :transaction),
          where: t.type == "donation_in",
          preload: [:transaction]
      )

    # The whole point: nothing, not a symbolic centavo.
    assert is_nil(entry.unit_cost)
    assert entry.transaction.notes == "Doado por uma escola"
  end

  test "the screen states the symbolic value it will declare", %{conn: conn, toy: toy} do
    view = pick(conn, toy)

    assert render(view) =~ "R$ 0,01"
  end

  test "a lot with no number is flagged for review", %{conn: conn, toy: toy} do
    view = pick(conn, toy)

    enter(view, %{"quantity" => "5"})

    lot = Repo.one!(from l in Lot, where: l.product_id == ^toy.id)

    assert is_nil(lot.lot_number)
    assert lot.needs_review
  end

  test "a second entry of the same lot number joins the lot, not a twin", %{
    conn: conn,
    toy: toy
  } do
    conn |> pick(toy) |> enter(%{"quantity" => "4", "lot_number" => "DOA-1"})
    conn |> pick(toy) |> enter(%{"quantity" => "6", "lot_number" => "DOA-1"})

    # Two rows for the same lot would split the balance and hide half of it from
    # a recall.
    assert Repo.aggregate(from(l in Lot, where: l.product_id == ^toy.id), :count) == 1
    assert Decimal.equal?(Inventory.balance(product_id: toy.id), Decimal.new(10))
  end

  test "refuses an entry with no quantity", %{conn: conn, toy: toy} do
    view = pick(conn, toy)

    assert enter(view, %{"quantity" => ""}) =~ "Diga quantas chegaram"
    assert Decimal.equal?(Inventory.balance(product_id: toy.id), Decimal.new(0))
  end

  test "records the expiry and the box when given", %{conn: conn, toy: toy, warehouse: warehouse} do
    box = box_fixture(%{code: "DN01", location_id: warehouse.id})
    view = pick(conn, toy)

    enter(view, %{
      "quantity" => "3",
      "lot_number" => "DOA-9",
      "expires_on" => "2029-06-30",
      "box_code" => box.code
    })

    lot = Repo.one!(from l in Lot, where: l.lot_number == "DOA-9")

    assert lot.expires_on == ~D[2029-06-30]
    refute lot.needs_review
    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(3))
  end

  test "the box list offers only boxes at the chosen location", %{conn: conn, toy: toy} do
    elsewhere = location_fixture(%{name: "Escritório SP"})
    _foreign = box_fixture(%{code: "SP01", location_id: elsewhere.id})

    html = conn |> pick(toy) |> render()

    # Goods in a box that is physically somewhere else would count twice: once at
    # the location on the entry, once in the box. The guard is in Inventory; the
    # screen never offers the mistake in the first place.
    refute html =~ "SP01"
  end

  test "an expiry read off the goods fills a blank on a known lot", %{conn: conn, toy: toy} do
    conn |> pick(toy) |> enter(%{"quantity" => "4", "lot_number" => "DOA-3"})

    conn
    |> pick(toy)
    |> enter(%{"quantity" => "2", "lot_number" => "DOA-3", "expires_on" => "2029-06-30"})

    lot = Repo.one!(from l in Lot, where: l.lot_number == "DOA-3")

    assert lot.expires_on == ~D[2029-06-30]
    assert Decimal.equal?(Inventory.balance(product_id: toy.id), Decimal.new(6))
  end

  describe "cataloguing something new" do
    test "creates a product the catalog never had and uses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entry")
      render_change(element(view, "#search-form"), %{"query" => "Bola de futebol"})

      html =
        view
        |> form("#new-product", %{"name" => "Bola de futebol", "stock_unit" => "UN"})
        |> render_submit()

      assert html =~ "adicionado ao catálogo"
      assert html =~ "entry-form"

      product = Repo.one!(from p in Product, where: p.name == "Bola de futebol")
      refute product.controlled
    end

    test "warns before breeding a near-duplicate", %{conn: conn} do
      product_fixture(%{name: "Gaze estéril 7,5 cm"})

      {:ok, view, _html} = live(conn, ~p"/entry")
      render_change(element(view, "#search-form"), %{"query" => "GAZE ESTERIL 7,5 CM"})

      html =
        view
        |> form("#new-product", %{"name" => "GAZE ESTERIL 7,5 CM", "stock_unit" => "UN"})
        |> render_submit()

      # The same item spelled two ways is the thing that killed the previous
      # system: the warning offers the existing row rather than just refusing.
      assert html =~ "já tem algo muito parecido"
      assert html =~ "Gaze estéril 7,5 cm"

      assert Repo.aggregate(
               from(p in EstoqueOS.Catalog.Product, where: ilike(p.name, "%gaze%")),
               :count
             ) == 1
    end

    # It shipped white-on-white. The list sits on `bg-base-100` inside an
    # `alert-warning`, which hands down the alert's text colour — and in the
    # light theme that colour is white. The products this warning exists to
    # offer were invisible, on the one screen where picking one of them is the
    # entire point.
    #
    # Asserting a class is crude, but the alternative is asserting nothing: the
    # bug is a colour, and it renders correctly in the dark theme.
    test "the near-duplicate list sets its own text colour", %{conn: conn} do
      product_fixture(%{name: "Gaze estéril 7,5 cm"})

      {:ok, view, _html} = live(conn, ~p"/entry")
      render_change(element(view, "#search-form"), %{"query" => "GAZE ESTERIL 7,5 CM"})

      html =
        view
        |> form("#new-product", %{"name" => "GAZE ESTERIL 7,5 CM", "stock_unit" => "UN"})
        |> render_submit()

      [list] = Regex.run(~r{<ul[^>]*class="[^"]*menu[^"]*"[^>]*>}, html)
      assert list =~ "text-base-content"
    end

    test "a second submit is the human saying these really are different", %{conn: conn} do
      product_fixture(%{name: "Gaze estéril 7,5 cm"})

      {:ok, view, _html} = live(conn, ~p"/entry")
      render_change(element(view, "#search-form"), %{"query" => "GAZE ESTERIL 7,5 CM"})

      view |> form("#new-product", %{"name" => "GAZE ESTERIL 7,5 CM"}) |> render_submit()
      html = view |> form("#new-product", %{"name" => "GAZE ESTERIL 7,5 CM"}) |> render_submit()

      assert html =~ "adicionado ao catálogo"

      assert Repo.aggregate(
               from(p in EstoqueOS.Catalog.Product, where: ilike(p.name, "%gaze%")),
               :count
             ) == 2
    end

    test "records whether the thing should ever have an expiry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entry")
      render_change(element(view, "#search-form"), %{"query" => "Boneca de pano"})

      # Unticked: a rag doll has no expiry and never will, so a lot arriving
      # without one is correct rather than an alarm.
      # An unticked checkbox posts nothing at all, which `form/3` cannot express
      # because it fills the field from the rendered `checked`. This is the exact
      # payload a browser sends.
      render_hook(view, "create_product", %{"name" => "Boneca de pano", "stock_unit" => "UN"})

      refute Repo.one!(from p in Product, where: p.name == "Boneca de pano").expiry_expected
    end

    test "defaults to expecting an expiry, because the catalog is medical supply",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/entry")
      render_change(element(view, "#search-form"), %{"query" => "Cetamina 50mg"})

      view |> form("#new-product", %{"name" => "Cetamina 50mg"}) |> render_submit()

      # A product nobody classified is better treated as one that should have
      # been dated: silence on an anesthetic is the expensive mistake.
      assert Repo.one!(from p in Product, where: p.name == "Cetamina 50mg").expiry_expected
    end
  end

  test "refuses an expiry that disagrees with the lot on record", %{conn: conn, toy: toy} do
    conn
    |> pick(toy)
    |> enter(%{"quantity" => "4", "lot_number" => "DOA-4", "expires_on" => "2029-06-30"})

    view = pick(conn, toy)

    html =
      enter(view, %{"quantity" => "2", "lot_number" => "DOA-4", "expires_on" => "2030-01-31"})

    # One of the two dates is wrong, and guessing which would put the wrong batch
    # in front of a recall.
    assert html =~ "outra data de validade"

    lot = Repo.one!(from l in Lot, where: l.lot_number == "DOA-4")
    assert lot.expires_on == ~D[2029-06-30]
    assert Decimal.equal?(Inventory.balance(product_id: toy.id), Decimal.new(4))
  end

  describe "what the goods cost" do
    setup %{conn: conn} do
      product_fixture(%{name: "Luva de procedimento"})
      {:ok, view, _html} = live(conn, ~p"/entry")
      view |> element("#search-form") |> render_change(%{"query" => "Luva"})
      view |> element("button", "Luva de procedimento") |> render_click()
      %{view: view}
    end

    test "a donation enters with no value at all, never a symbolic cent", %{view: view} do
      view
      |> element("#entry-form")
      |> render_submit(%{"quantity" => "40", "origin" => "donation"})

      assert %{type: "donation_in", entries: [%{unit_cost: nil}]} = last_transaction()
    end

    test "goods bought without an invoice keep the price that was paid", %{view: view} do
      view
      |> element("#entry-form")
      |> render_submit(%{"quantity" => "40", "origin" => "purchase", "unit_cost" => "2,50"})

      assert %{type: "purchase_in", entries: [%{unit_cost: cost}]} = last_transaction()
      assert Decimal.equal?(cost, Decimal.new("2.50"))
    end

    test "a total is divided by what actually arrived", %{view: view} do
      view
      |> element("#entry-form")
      |> render_submit(%{"quantity" => "40", "origin" => "purchase", "total_cost" => "100"})

      assert %{entries: [%{unit_cost: cost}]} = last_transaction()
      assert Decimal.equal?(cost, Decimal.new("2.5"))
    end

    test "a purchase nobody priced still enters, with no value on record", %{view: view} do
      view
      |> element("#entry-form")
      |> render_submit(%{"quantity" => "40", "origin" => "purchase"})

      assert %{type: "purchase_in", entries: [%{unit_cost: nil}]} = last_transaction()
    end
  end

  defp last_transaction do
    import Ecto.Query

    EstoqueOS.Inventory.Transaction
    |> order_by(desc: :id)
    |> limit(1)
    |> EstoqueOS.Repo.one!()
    |> EstoqueOS.Repo.preload(:entries)
  end

  describe "the box picker" do
    test "a code the warehouse has not registered yet creates the box here", %{
      conn: conn,
      warehouse: warehouse
    } do
      product = product_fixture(%{name: "Fita microporosa"})

      {:ok, view, _html} = live(conn, ~p"/entry")

      view |> element("#search-form") |> render_change(%{"query" => "Fita"})
      view |> element("button", "Fita microporosa") |> render_click()

      html =
        view
        |> element("#entry-form")
        |> render_submit(%{"quantity" => "12", "box_code" => "ZZ99"})

      # Asked, not done. A code one character wrong makes a box that exists, is
      # empty, and is never opened again.
      assert html =~ "Criar a caixa ZZ99?"
      refute EstoqueOS.Repo.get_by(EstoqueOS.Inventory.Box, code: "ZZ99")

      html = view |> element("#confirm-new-box") |> render_click()
      assert html =~ "Caixa ZZ99 criada aqui"

      box = EstoqueOS.Repo.get_by!(EstoqueOS.Inventory.Box, code: "ZZ99")
      assert box.location_id == warehouse.id
      assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(12))
      assert product.id
    end

    test "declining the new box keeps the entry on screen to be corrected", %{conn: conn} do
      product_fixture(%{name: "Fita microporosa"})

      {:ok, view, _html} = live(conn, ~p"/entry")

      view |> element("#search-form") |> render_change(%{"query" => "Fita"})
      view |> element("button", "Fita microporosa") |> render_click()

      view
      |> element("#entry-form")
      |> render_submit(%{"quantity" => "12", "lot_number" => "L-7", "box_code" => "ZZ99"})

      html = view |> element("#cancel-new-box") |> render_click()

      refute EstoqueOS.Repo.get_by(EstoqueOS.Inventory.Box, code: "ZZ99")
      refute html =~ "Criar a caixa"

      # The quantity and the lot survive: the box code was wrong, not the count.
      # Retyping a counted number is how a real one gets replaced by a guess.
      assert html =~ ~s(name="quantity" value="12")
      assert html =~ ~s(name="lot_number" value="L-7")
      assert html =~ ~s(name="box_code" value="")
    end

    test "a box that lives somewhere else is refused, not moved", %{conn: conn} do
      elsewhere = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
      box_fixture(%{code: "MT01", location_id: elsewhere.id})
      product_fixture(%{name: "Esparadrapo"})

      {:ok, view, _html} = live(conn, ~p"/entry")

      view |> element("#search-form") |> render_change(%{"query" => "Esparadrapo"})
      view |> element("button", "Esparadrapo") |> render_click()

      html =
        view
        |> element("#entry-form")
        |> render_submit(%{"quantity" => "5", "box_code" => "MT01"})

      assert html =~ "está em Missão Tefé"
      assert Decimal.equal?(Inventory.balance(location_id: elsewhere.id), Decimal.new(0))
    end
  end

  describe "where it belongs" do
    test "preselects the box that already holds this product, and says why", context do
      %{conn: conn, toy: toy, warehouse: warehouse} = context
      box = box_fixture(%{code: "SG01", location_id: warehouse.id})
      lot = lot_fixture(%{product_id: toy.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, location_id: warehouse.id, box_id: box.id, quantity: Decimal.new(5)}
          ]
        })

      html = conn |> pick(toy) |> render()

      # Splitting one product across two boxes is how a recall finds half of it,
      # so the box that already has it is chosen rather than merely listed.
      assert html =~ ~s(value="#{box.code}")
      assert html =~ "já tem"
      assert html =~ "um produto, uma caixa"
    end

    test "says nothing when no box is related", %{conn: conn, toy: toy, warehouse: warehouse} do
      _empty = box_fixture(%{code: "SG02", location_id: warehouse.id})

      html = conn |> pick(toy) |> render()

      # A suggestion with no reason is noise, and noise is what makes people stop
      # reading suggestions.
      refute html =~ "um produto, uma caixa"
      refute html =~ "do mesmo grupo"
    end
  end
end
