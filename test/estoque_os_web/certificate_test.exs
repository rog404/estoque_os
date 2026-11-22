defmodule EstoqueOSWeb.CertificateTest do
  @moduledoc """
  The two certificates a hospital signs, built from the manual issue itself.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Inventory, Outbound, Repo}

  setup :register_and_log_in_operator

  defp visible_text(html) do
    html
    |> String.replace(~r{<script.*?</script>}s, " ")
    |> String.replace(~r{<[^>]*>}s, " ")
  end

  defp donated_issue(opts \\ []) do
    product = product_fixture(%{name: "Compressa de gaze"})
    lot = lot_fixture(%{product_id: product.id, lot_number: "L-99"})
    location = location_fixture()

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: location.id,
            quantity: 50,
            unit_cost: Decimal.new("2.50")
          }
        ]
      })

    {:ok, transaction} =
      Outbound.issue(product.id, 30, %{
        location_id: location.id,
        user_id: actor_id(),
        destination: opts[:destination] || "donation",
        recipient_name: "Hospital Regional de Tefé",
        recipient_tax_id: "12.345.678/0001-95"
      })

    transaction
  end

  test "prints the termo de doação from the issue", %{conn: conn} do
    transaction = donated_issue()

    conn = get(conn, ~p"/issues/#{transaction.id}/termo/doacao")
    body = html_response(conn, 200)

    assert body =~ "Hospital Regional de Tefé"
    assert body =~ "Compressa de gaze"
    assert body =~ "L-99"

    # Quantities are stated as handed over, not as the ledger's negative. Strip
    # tags before the refute: `-30` can appear inside a Tailwind class.
    assert body =~ "30"
    refute visible_text(body) =~ "-30"
  end

  test "prints the termo de recebimento too", %{conn: conn} do
    transaction = donated_issue()

    body = conn |> get(~p"/issues/#{transaction.id}/termo/recebimento") |> html_response(200)

    assert body =~ "Hospital Regional de Tefé"
  end

  # The ledger keeps NULL for "no value informed"; a signed document needs a figure per line.
  test "declares donated goods at the symbolic minimum, and the total agrees", %{conn: conn} do
    toy = product_fixture(%{name: "Brinquedo doado"})
    lot = lot_fixture(%{product_id: toy.id})
    location = location_fixture()

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "donation_in",
        user_id: actor_id(),
        entries: [%{lot_id: lot.id, location_id: location.id, quantity: 20}]
      })

    {:ok, transaction} =
      Outbound.issue(toy.id, 7, %{
        location_id: location.id,
        user_id: actor_id(),
        destination: "donation",
        recipient_name: "Casa de Apoio"
      })

    body = conn |> get(~p"/issues/#{transaction.id}/termo/doacao") |> html_response(200)

    assert body =~ "R$ 0,01"
    assert body =~ "R$ 0,07"
    assert body =~ "valor simbólico"

    entry = hd(Repo.preload(transaction, :entries).entries)
    assert is_nil(entry.unit_cost)
  end

  test "refuses to certify an issue that was not a donation", %{conn: conn} do
    transaction = donated_issue(destination: "pacu")

    conn = get(conn, ~p"/issues/#{transaction.id}/termo/doacao")

    assert redirected_to(conn) == ~p"/issues"
  end

  test "the issue appears in the listing, filterable by destination", %{conn: conn} do
    import Phoenix.LiveViewTest

    donated_issue()

    {:ok, _view, html} = live(conn, ~p"/issues?destination=donation")

    assert html =~ "Hospital Regional de Tefé"
    assert html =~ "Compressa de gaze"

    {:ok, _view, other} = live(conn, ~p"/issues?destination=pacu")
    refute other =~ "Hospital Regional de Tefé"
  end
end
