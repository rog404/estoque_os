defmodule EstoqueOSWeb.StockFilterTest do
  @moduledoc """
  Finding one thing in a stock of hundreds. One box searches what a person
  would actually type: the product, the lot on the label, or the code painted
  on the side of the box.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Catalog, Inventory, Repo}
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Invoices.Invoice

  setup :register_and_log_in_user

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    mission = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})
    box = box_fixture(%{code: "SF01", location_id: warehouse.id})

    electrode = product_fixture(%{name: "Eletrodo ECG adulto"})
    fentanyl = product_fixture(%{name: "Fentanila 50mcg", controlled: true})
    gauze = product_fixture(%{name: "Compressa de gaze"})

    {:ok, _} =
      Catalog.confirm_conversion(%{product_id: electrode.id, from_unit: "PT", factor: 50})

    stock_in(lot_fixture(%{product_id: electrode.id, lot_number: "114391U02"}), warehouse, 300,
      box_id: box.id
    )

    stock_in(
      lot_fixture(%{
        product_id: fentanyl.id,
        lot_number: "FT-9",
        expires_on: Date.add(Date.utc_today(), 20)
      }),
      warehouse,
      20
    )

    stock_in(lot_fixture(%{product_id: gauze.id, lot_number: "GZ-1"}), mission, 500)

    %{warehouse: warehouse, mission: mission, box: box}
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

  # An unchecked checkbox is not submitted at all, so the defaults carry only
  # the two fields a browser always sends. A test that hands the filter form a
  # value the browser never produces is a test that can pass while the screen is
  # broken — which is exactly what happened here: the checkboxes send "true" and
  # the view was reading "on".
  defp filter(view, params) do
    defaults = %{"search" => "", "location_id" => ""}

    view |> element("#filter-form") |> render_change(Map.merge(defaults, params))
  end

  # The value the rendered checkbox would actually send, read off the page
  # rather than typed here.
  defp checkbox_value(html, name) do
    case Regex.run(~r/<input[^>]*name="#{name}"[^>]*>/, html) do
      [input] ->
        [_all, value] = Regex.run(~r/value="([^"]*)"/, input)
        value

      nil ->
        flunk("there is no #{name} checkbox on the page")
    end
  end

  test "searches by product name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "eletrodo"})

    assert html =~ "Eletrodo ECG adulto"
    refute html =~ "Compressa de gaze"
  end

  test "searches by the lot printed on the label", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "114391"})

    assert html =~ "Eletrodo ECG adulto"
    refute html =~ "Fentanila"
  end

  test "searches by the code painted on the box", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "SF01"})

    assert html =~ "Eletrodo ECG adulto"
    refute html =~ "Compressa de gaze"
  end

  test "filters by location", %{conn: conn, mission: mission} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"location_id" => "#{mission.id}"})

    assert html =~ "Compressa de gaze"
    refute html =~ "Eletrodo ECG adulto"
  end

  test "filters to what is expiring and to controlled substances", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/stock")

    expiring = filter(view, %{"only_expiring" => checkbox_value(html, "only_expiring")})
    assert expiring =~ "Fentanila"
    refute expiring =~ "Compressa de gaze"

    controlled = filter(view, %{"only_controlled" => checkbox_value(html, "only_controlled")})
    assert controlled =~ "Fentanila"
    refute controlled =~ "Eletrodo ECG adulto"
  end

  test "filters to the goods that arrived without lot data", %{conn: conn, warehouse: warehouse} do
    product = product_fixture(%{name: "Atadura doada"})
    lot = lot_fixture(%{product_id: product.id, lot_number: nil, needs_review: true})
    stock_in(lot, warehouse, 12)

    {:ok, view, html} = live(conn, ~p"/stock")

    # The bug all three of these hold: `<.check>` renders value="true" and the
    # view compared against "on", so every checkbox in the filter panel was dead
    # on the page while the tests handed the event an "on" no browser sends.
    # Both halves are read from the DOM now, so they cannot drift apart again.
    filtered = filter(view, %{"only_needs_review" => checkbox_value(html, "only_needs_review")})

    assert filtered =~ "Atadura doada"
    refute filtered =~ "Eletrodo ECG adulto"
  end

  test "a link may still turn a filter on from the address bar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/stock?expiring=on")

    assert html =~ "Fentanila"
    refute html =~ "Compressa de gaze"
  end

  test "clearing the filters clears the one for missing lot data too", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/stock")

    filter(view, %{"only_needs_review" => checkbox_value(html, "only_needs_review")})

    cleared = view |> element("#filter-form button", "Limpar filtros") |> render_click()

    assert cleared =~ "Eletrodo ECG adulto"
    assert cleared =~ "Compressa de gaze"
  end

  test "says so when nothing matches, without pretending stock is empty", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "coisa que não existe"})

    assert html =~ "Nada aqui corresponde"
    refute html =~ "O estoque está vazio"
  end

  test "shows the unit and the packaging the team confirmed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "eletrodo"})

    # Stock is counted in individual units; the supplier sells packs of 50.
    assert html =~ "UN"
    assert html =~ "PT/50"
  end

  test "clicking the sorted column flips its direction", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/stock")

    # Product ascending is the default, so the first click reverses it.
    assert position(html, "Compressa de gaze") < position(html, "Fentanila")

    descending = view |> element("th button", "Produto") |> render_click()
    assert position(descending, "Fentanila") < position(descending, "Compressa de gaze")

    ascending = view |> element("th button", "Produto") |> render_click()
    assert position(ascending, "Compressa de gaze") < position(ascending, "Fentanila")
  end

  test "a lot with no expiry sorts last, not first", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = view |> element("th button", "Validade") |> render_click()

    # Gaze has no expiry date; an unknown date is not "the oldest".
    assert position(html, "Fentanila") < position(html, "Compressa de gaze")
  end

  test "renders one table that collapses into blocks on a phone", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/stock")

    # One DOM, two shapes: rendering a separate card list duplicated every id
    # inside a cell, which is invalid HTML and breaks LiveView.
    assert html =~ "data-table"
    assert length(String.split(html, "<table")) - 1 == 1

    # Each cell carries the label its header shows on a wide screen, so the
    # collapsed form still says what the number is.
    assert html =~ ~s(data-label="Quantidade")
    assert html =~ ~s(data-label="Validade")

    # Zebra striping is the tell of a generic record set.
    refute html =~ "table-zebra"
  end

  test "says a balance is presumed in words, not in a 10px badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "eletrodo"})

    assert html =~ "presumido · nunca contada"

    # Not "no badge anywhere on the page" — other states legitimately use one,
    # and a test that fails because an unrelated badge appeared elsewhere is a
    # test people learn to delete. What must not come back is *this* claim
    # shrunk into a badge, so the badges are asked what they say.
    refute has_element?(view, ".badge", "presumido")
  end

  test "pages instead of rendering the whole warehouse at once", %{conn: conn} do
    warehouse = Locations.default_location()
    product = product_fixture(%{name: "Gaze paginada"})

    # 60 positions of one product: more than a page.
    for index <- 1..60 do
      lot = lot_fixture(%{product_id: product.id, lot_number: "PG-#{index}"})
      stock_in(lot, warehouse, 10)
    end

    {:ok, view, html} = live(conn, ~p"/stock")

    assert html =~ "Página 1 de"
    assert length(String.split(html, "PG-")) - 1 <= 50

    second = view |> element("button", "Próxima") |> render_click()
    assert second =~ "Página 2 de"
  end

  test "filtering returns to the first page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "eletrodo"})

    assert html =~ "Eletrodo ECG adulto"
    refute html =~ "Página 2"
  end

  test "finds a product by the GTIN on the box", %{conn: conn} do
    product = product_fixture(%{name: "Cateter intravenoso 22G"})
    product_identifier_fixture(%{kind: "gtin", value: "7898733218198", product_id: product.id})
    warehouse = Locations.default_location()
    stock_in(lot_fixture(%{product_id: product.id}), warehouse, 100)

    {:ok, view, _html} = live(conn, ~p"/stock")
    html = filter(view, %{"search" => "7898733218198"})

    assert html =~ "Cateter intravenoso 22G"
    refute html =~ "Compressa de gaze"
  end

  test "finds what is left of a delivery by the number printed on the invoice",
       %{conn: conn, warehouse: warehouse} do
    supplier = supplier_fixture()

    {:ok, invoice} =
      %Invoice{}
      |> Invoice.changeset(%{
        access_key: "35260411222333000424550010009770981447856989",
        number: "977098",
        series: "1",
        issued_on: ~D[2026-04-23],
        raw_xml: "<nfeProc/>",
        supplier_id: supplier.id
      })
      |> Repo.insert()

    product = product_fixture(%{name: "Avental cirúrgico EG"})
    lot = lot_fixture(%{product_id: product.id, lot_number: "AV-7"})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        invoice_id: invoice.id,
        entries: [
          %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(40)}
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "977098"})

    assert html =~ "Avental cirúrgico EG"
    refute html =~ "Compressa de gaze"
  end

  defp position(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} -> index
      :nomatch -> flunk("#{needle} is not on the page")
    end
  end

  test "a lot without an expiry date is neither expiring nor expired", %{conn: conn} do
    # This raised in the template before expiring/expired were real booleans.
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "gaze"})

    assert html =~ "Compressa de gaze"
    refute html =~ "vencido"
    refute html =~ "vencendo"
  end
end
