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
  # Two forms now, and they behave differently on purpose: the search answers as
  # you type, the panel waits for "Aplicar". A test that drove both through one
  # form would not notice if that stopped being true.
  defp filter(view, params) do
    {search, panel} = Map.pop(params, "search")

    if search, do: view |> element("#search-form") |> render_change(%{"search" => search})

    if panel == %{} do
      render(view)
    else
      view |> element("#filter-form") |> render_submit(panel)
    end
  end

  # The values the rendered droplist would actually send, read off the page
  # rather than typed here. The three checkboxes became one "Situação" list, and
  # this is what keeps the test asking the DOM what it offers instead of
  # assuming.
  defp situation_values(html) do
    [panel] = Regex.run(~r/<select[^>]*name="situation\[\]".*?<\/select>/s, html)

    Regex.scan(~r/value="([^"]*)"/, panel) |> Enum.map(fn [_, v] -> v end)
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

    html = filter(view, %{"location_id" => ["#{mission.id}"]})

    assert html =~ "Compressa de gaze"
    refute html =~ "Eletrodo ECG adulto"
  end

  test "filters to what is expiring and to controlled substances", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/stock")

    # Read off the page: the panel offers these, so the test cannot drift from
    # what a browser would post.
    assert "expiring" in situation_values(html)
    assert "controlled" in situation_values(html)

    expiring = filter(view, %{"situation" => ["expiring"]})
    assert expiring =~ "Fentanila"
    refute expiring =~ "Compressa de gaze"

    controlled = filter(view, %{"situation" => ["controlled"]})
    assert controlled =~ "Fentanila"
    refute controlled =~ "Eletrodo ECG adulto"
  end

  # A union, not an intersection: somebody chasing problems means "either of
  # these", and three separate conditions would have meant "all at once" and
  # answered almost nothing.
  test "several situations at once mean either of them", %{conn: conn, warehouse: warehouse} do
    expired = product_fixture(%{name: "Propofol vencido"})

    stock_in(
      lot_fixture(%{
        product_id: expired.id,
        lot_number: "PP-OLD",
        expires_on: Date.add(Date.utc_today(), -3)
      }),
      warehouse,
      15
    )

    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"situation" => ["expired", "controlled"]})

    assert html =~ "Propofol vencido"
    assert html =~ "Fentanila"
    refute html =~ "Compressa de gaze"
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
    assert "review" in situation_values(html)

    filtered = filter(view, %{"situation" => ["review"]})

    assert filtered =~ "Atadura doada"
    refute filtered =~ "Eletrodo ECG adulto"
  end

  test "a link may still turn a filter on from the address bar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/stock?expiring=on")

    assert html =~ "Fentanila"
    refute html =~ "Compressa de gaze"
  end

  test "clearing the filters clears the one for missing lot data too", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    filter(view, %{"situation" => ["review"]})

    cleared = view |> element("#filter-form button", "Limpar filtros") |> render_click()

    assert cleared =~ "Eletrodo ECG adulto"
    assert cleared =~ "Compressa de gaze"
  end

  test "filters by several locations at once", %{
    conn: conn,
    warehouse: warehouse,
    mission: mission
  } do
    {:ok, view, _html} = live(conn, ~p"/stock")

    # One place at a time was two searches and a subtraction done in somebody's
    # head, while the goods were on a truck between the two.
    html = filter(view, %{"location_id" => ["#{warehouse.id}", "#{mission.id}"]})

    assert html =~ "Eletrodo ECG adulto"
    assert html =~ "Compressa de gaze"

    one = filter(view, %{"location_id" => ["#{mission.id}"]})

    assert one =~ "Compressa de gaze"
    refute one =~ "Eletrodo ECG adulto"
  end

  test "the panel waits for Aplicar, and the search does not", %{conn: conn, mission: mission} do
    {:ok, view, html} = live(conn, ~p"/stock")

    # The panel carries no `phx-change`, and that absence is the whole
    # guarantee: picking three filters used to be three reloads, two of them
    # showing something nobody had asked for yet. LiveViewTest refuses to fire a
    # change on a form without one, so it is asserted directly.
    assert [filter_form] = Regex.run(~r{<form[^>]*id="filter-form"[^>]*>}, html)
    refute filter_form =~ "phx-change"
    assert filter_form =~ ~s(phx-submit="filter")

    assert [search_form] = Regex.run(~r{<form[^>]*id="search-form"[^>]*>}, html)
    assert search_form =~ ~s(phx-change="search")

    applied =
      view |> element("#filter-form") |> render_submit(%{"location_id" => ["#{mission.id}"]})

    refute applied =~ "Eletrodo ECG adulto"
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

  # The claim itself is what matters and it has not moved: a balance nobody has
  # counted says so. What changed is the room it takes. Two lines of prose per
  # row turned every long list into paragraphs, so it is a mark on the box label
  # it qualifies — with the sentence on hover *and* in the accessible name, which
  # is what keeps this from being the 10px ghost badge it once was.
  test "says a balance is presumed, on the box it is a claim about", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stock")

    html = filter(view, %{"search" => "eletrodo"})

    # Readable by a screen reader and on hover, not colour alone.
    assert html =~ ~s(data-tip="presumido · nunca contada")
    assert has_element?(view, ".sr-only", "presumido · nunca contada")

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
