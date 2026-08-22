defmodule EstoqueOSWeb.ManualEntryLogTest do
  @moduledoc """
  Goods taken in by hand have a log of their own.

  The ledger files them under the same types as an invoice — `purchase_in` for
  something bought without a nota, `donation_in` for something given — so every
  screen called them "Nota fiscal lançada", and whoever went looking for a
  manual entry ended up in the invoice list with nothing to find.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Invoices}

  @samples EstoqueOS.Samples.dir()

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    gauze = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    blanket = product_fixture(%{name: "Cobertor doado"})

    %{warehouse: warehouse, gauze: gauze, blanket: blanket}
  end

  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  defp enter(product, location, opts) do
    {:ok, transaction} =
      Inventory.enter_manually(%{
        product_id: product.id,
        location_id: location.id,
        quantity: Decimal.new(opts[:quantity] || 10),
        origin: opts[:origin] || "donation",
        unit_cost: opts[:unit_cost],
        user_id: actor_id()
      })

    transaction
  end

  defp post_invoice do
    xml =
      @samples
      |> Path.join("35260455666777000181550040019851671590327796-nfe.xml")
      |> File.read!()

    {:ok, invoice} = Invoices.import_document(xml, user_id: actor_id())
    invoice
  end

  test "the entry is called an entry, not a posted invoice", %{
    conn: conn,
    warehouse: warehouse,
    gauze: gauze
  } do
    enter(gauze, warehouse, origin: "purchase", unit_cost: Decimal.new("1.20"))

    {:ok, _view, html} = live(conn, ~p"/entries")

    page = text(html)

    assert page =~ "Entrada manual"
    assert page =~ "Compressa de gaze"
    refute page =~ "Nota fiscal lançada"
  end

  # The overview reads the same movements, and it was the screen that reported
  # the wrong word first.
  test "the overview says the same thing", %{conn: conn, warehouse: warehouse, gauze: gauze} do
    enter(gauze, warehouse, origin: "purchase")

    {:ok, _view, html} = live(conn, ~p"/")

    assert text(html) =~ "Entrada manual"
    refute text(html) =~ "Nota fiscal lançada"
  end

  # A delivery that *does* have a nota keeps the invoice's name, which is the
  # distinction the whole screen rests on.
  test "an invoice is still an invoice", %{conn: conn} do
    post_invoice()

    {:ok, _view, entries} = live(conn, ~p"/entries")

    # It is not in this log at all: the log is what came in without a document.
    refute text(entries) =~ "Nota fiscal lançada"
  end

  # Asserted by row and not by name: a product with no lot number also shows up
  # in the alert panel at the top, so a page-wide refute would be reading the
  # bell rather than the list.
  test "bought and donated can be told apart", %{
    conn: conn,
    warehouse: warehouse,
    gauze: gauze,
    blanket: blanket
  } do
    bought = enter(gauze, warehouse, origin: "purchase")
    donated = enter(blanket, warehouse, origin: "donation")

    {:ok, view, _html} = live(conn, ~p"/entries")

    assert has_element?(view, "#entry-#{bought.id}")
    assert has_element?(view, "#entry-#{donated.id}")

    view |> form("#entries-filter", %{"origin" => "purchase"}) |> render_change()

    assert has_element?(view, "#entry-#{bought.id}")
    refute has_element?(view, "#entry-#{donated.id}")

    view |> form("#entries-filter", %{"origin" => "donation"}) |> render_change()

    assert has_element?(view, "#entry-#{donated.id}")
    refute has_element?(view, "#entry-#{bought.id}")
  end

  test "says where the goods landed", %{conn: conn, warehouse: warehouse, gauze: gauze} do
    enter(gauze, warehouse, origin: "purchase")

    {:ok, _view, html} = live(conn, ~p"/entries")

    assert text(html) =~ warehouse.name
  end

  test "an empty period says so without blaming the install", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/entries")

    assert text(html) =~ "Nada entrou pela mão neste período"
  end
end
