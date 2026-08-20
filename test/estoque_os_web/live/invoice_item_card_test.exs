defmodule EstoqueOSWeb.InvoiceItemCardTest do
  @moduledoc """
  The first thing the ONG said about this screen: confirming a line wrecked it.

  The lines were rows of one table whose columns were sized from their content,
  so resolving one changed the width of all of them, and the product name — long,
  and longer than the supplier's own wording — landed in a badge that could not
  wrap. A line has to *settle* when it is confirmed. That is what these hold.
  """

  # Not async: imports the same real invoice as the other invoice suites.
  use EstoqueOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Invoices

  @samples EstoqueOS.Samples.dir()
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"

  setup :register_and_log_in_operator

  setup do
    location_fixture(%{name: "Estoque Principal", kind: "warehouse"})

    {:ok, invoice} =
      @samples |> Path.join(@atlantica) |> File.read!() |> Invoices.import_document()

    %{invoice: invoice, item: hd(invoice.items), product: product_fixture(%{name: "Eletrodo"})}
  end

  defp card(html, item) do
    case Regex.run(~r{<article[^>]*id="item-#{item.id}".*?</article>}s, html) do
      [card] -> card
      nil -> flunk("no card for item #{item.id}")
    end
  end

  test "an unconfirmed line asks for the product and shows the price it would post", %{
    conn: conn,
    invoice: invoice,
    item: item
  } do
    {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

    card = card(html, item)

    # The supplier's own wording, in full: until somebody matches it, it is the
    # only description of the goods that exists.
    assert card =~ item.description
    assert card =~ "Buscar no catálogo"
    assert card =~ "Preço unitário"
  end

  test "confirming a line collapses it to a summary and keeps the price loud", %{
    conn: conn,
    invoice: invoice,
    item: item,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

    html =
      view
      |> element("#resolve-#{item.id}")
      |> render_submit(%{"product_id" => "#{product.id}", "conversion_factor" => "50"})

    card = card(html, item)

    assert card =~ "confirmado"
    assert card =~ product.name
    # What the line decided, on one line.
    assert card =~ "1 PT = 50"
    # And the number this whole screen exists to produce.
    assert card =~ "R$ 0,2695"

    # The form is gone: the line has settled.
    refute card =~ "Buscar no catálogo"
    refute card =~ "Selecione um produto"
  end

  test "the unit price answers as the conversion factor is typed, before anything is confirmed",
       %{conn: conn, invoice: invoice, item: item} do
    {:ok, view, html} = live(conn, ~p"/invoices/#{invoice.id}")

    # The price the invoice's own factor implies, before anyone touches the field.
    assert card(html, item) =~ "R$ 0,2695"

    html =
      view
      |> element("#resolve-#{item.id}")
      |> render_change(%{"conversion_factor" => "10"})

    # A different factor, a different price — seeing it move is how a wrong
    # factor gets caught, and it happens without a submit.
    assert card(html, item) =~ "R$ 1,3475"
    assert card(html, item) =~ "Buscar no catálogo"

    # Nothing was written: the line is still open, still asking for a product.
    refute Invoices.get_invoice!(invoice.id)
           |> Map.fetch!(:items)
           |> hd()
           |> Map.fetch!(:product_id)
  end

  test "a confirmed line can be reopened and closes again", %{
    conn: conn,
    invoice: invoice,
    item: item,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

    view
    |> element("#resolve-#{item.id}")
    |> render_submit(%{"product_id" => "#{product.id}", "conversion_factor" => "50"})

    html =
      view |> element(~s(button[phx-value-item="#{item.id}"][phx-click="edit"])) |> render_click()

    # Reopened, the line says what it currently is rather than dropping the
    # operator back into an empty search. The search box is one press away,
    # behind "Alterar" — reopening a line to fix its lot number should not cost
    # you the product you already matched.
    reopened = card(html, item)
    assert reopened =~ product.name
    assert reopened =~ ~s(phx-click="unpick")
    refute reopened =~ "Buscar no catálogo"

    html =
      view
      |> element(~s(button[phx-value-item="#{item.id}"][phx-click="cancel_edit"]))
      |> render_click()

    assert card(html, item) =~ "confirmado"
    refute card(html, item) =~ "Buscar no catálogo"
  end

  # The two controls that used to ask the same question. Typing went into one
  # and the answers came out of the other, so the search looked broken and the
  # suggestions looked like they came from opening an empty droplist.
  defp open_matches(view, item) do
    view |> element("#search-#{item.id} input[name=query]") |> render_focus()
  end

  test "an unresolved line asks once, and offers creating last", %{
    conn: conn,
    invoice: invoice,
    item: item
  } do
    {:ok, view, html} = live(conn, ~p"/invoices/#{invoice.id}")

    card = card(html, item)

    assert card =~ "Buscar no catálogo"

    # The second control is gone, not merely relabelled. Refuting the visible
    # words would pass on the comment above the markup that explains why it
    # went — the tag-matching trap this repo keeps stepping in.
    refute card =~ ~r{<select[^>]*name="product_id"}

    # The name a new product would get is not asked for until it is needed.
    refute card =~ ~s(name="new_product_name")

    card = view |> open_matches(item) |> card(item)

    # Creating comes after the matches: offered first it is the fastest path,
    # and the catalog fills with the same item spelled three ways.
    matches = Regex.run(~r{<ul[^>]*id="matches-#{item.id}".*?</ul>}s, card) |> hd()
    assert String.contains?(matches, "choose_new")

    last_pick =
      ~r{phx-click="pick"}
      |> Regex.scan(matches, return: :index)
      |> List.last()
      |> hd()
      |> elem(0)

    [{create_at, _}] = Regex.run(~r{phx-click="choose_new"}, matches, return: :index)
    assert create_at > last_pick
  end

  # The matches belong to the field, the way any suggestion list does. Ten rows
  # of catalog under every unresolved line is a card the operator scrolls past
  # on the nine lines in ten that need one glance and one click.
  test "the matches are a suggestion of the field, not a block under it", %{
    conn: conn,
    invoice: invoice,
    item: item
  } do
    {:ok, view, html} = live(conn, ~p"/invoices/#{invoice.id}")

    refute card(html, item) =~ ~s(id="matches-#{item.id}")

    assert open_matches(view, item) |> card(item) =~ ~s(id="matches-#{item.id}")

    # And clicking away puts it back. `LiveViewTest` has no click-away, so the
    # binding is asserted and the event it sends is driven by hand.
    assert card(render(view), item) =~ ~s(phx-click-away="close_matches")

    away = render_click(view, "close_matches", %{"item" => "#{item.id}"})

    refute card(away, item) =~ ~s(id="matches-#{item.id}")
  end

  # Typing has to show its own results. A search whose answers stay hidden is
  # exactly the bug this screen was rebuilt to fix.
  test "typing opens the list even if it was closed", %{
    conn: conn,
    invoice: invoice,
    item: item,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

    html =
      view
      |> form("#search-#{item.id}", %{"query" => "eletro"})
      |> render_change()

    card = card(html, item)

    assert card =~ ~s(id="matches-#{item.id}")
    assert card =~ product.name
  end

  test "picking a match names it and hides the search", %{
    conn: conn,
    invoice: invoice,
    item: item,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

    open_matches(view, item)

    html =
      view
      |> element(~s(#matches-#{item.id} button[phx-value-product="#{product.id}"]))
      |> render_click()

    card = card(html, item)

    # Chosen, not yet confirmed: the conversion factor still has to be right.
    assert card =~ product.name
    refute card =~ "Buscar no catálogo"
    assert card =~ ~s(name="product_id" value="#{product.id}")
    refute card =~ "confirmado"
  end

  test "choosing to create reveals the name, and only then", %{
    conn: conn,
    invoice: invoice,
    item: item
  } do
    {:ok, view, _html} = live(conn, ~p"/invoices/#{invoice.id}")

    open_matches(view, item)

    html =
      view
      |> element("#matches-#{item.id} button[phx-click=choose_new]")
      |> render_click()

    card = card(html, item)

    assert card =~ "new_product_name"
    assert card =~ ~s(name="product_id" value="__new__")
  end

  # Confirming one line must not disturb the others — the reflow was the whole
  # complaint.
  test "confirming one line leaves the rest exactly where they were", %{
    conn: conn,
    invoice: invoice,
    item: item,
    product: product
  } do
    {:ok, view, html} = live(conn, ~p"/invoices/#{invoice.id}")

    order = fn page -> Regex.scan(~r/id="item-(\d+)"/, page) |> Enum.map(&List.last/1) end
    before = order.(html)

    after_confirming =
      view
      |> element("#resolve-#{item.id}")
      |> render_submit(%{"product_id" => "#{product.id}", "conversion_factor" => "50"})
      |> order.()

    assert after_confirming == before
  end
end
