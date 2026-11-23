defmodule EstoqueOSWeb.BlindCountTest do
  @moduledoc """
  A counter shown the expected number writes it down. So the expected quantity
  must be absent while counting and present afterwards; both halves are pinned.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  setup :register_and_log_in_operator

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal"})
    box = box_fixture(%{code: "CT01", location_id: warehouse.id})
    product = product_fixture(%{name: "Gaze estéril"})
    lot = lot_fixture(%{product_id: product.id, lot_number: "L-777"})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: warehouse.id, box_id: box.id, quantity: 100}
        ]
      })

    %{box: box, lot: lot}
  end

  # `refute html =~ ...` matches markup too, so absence checks strip the tags first.
  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")

  test "does not reveal the expected quantity while counting", %{conn: conn, box: box} do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    # Scope to the sheet (the nav has `bg-base-100`) and strip tags (the lot id
    # appears in `id="row-100"` and `name="counts[100]"`).
    sheet = text(view |> element("#count-form") |> render())

    assert sheet =~ "Gaze estéril"
    assert sheet =~ "L-777"

    refute sheet =~ "100"
    refute sheet =~ "presume"
  end

  # The recount must not say by how much the first count was off, or it is as
  # compromised as a sighted one.
  test "asks for a recount without saying how far off it was", %{
    conn: conn,
    box: box,
    lot: lot
  } do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "98"}})

    # Tags stripped: "-2" also lives inside the class `w-28`.
    sheet = text(view |> element("#recount-form") |> render())

    assert sheet =~ "Gaze estéril"
    refute sheet =~ "100"
    refute sheet =~ "-2"

    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(100))
  end

  test "reveals the divergence once the count is fixed and recorded", %{
    conn: conn,
    box: box,
    lot: lot
  } do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "98"}})
    html = render_submit(element(view, "#recount-form"), %{"counts" => %{"#{lot.id}" => "98"}})

    assert html =~ "98"
    assert html =~ "100"
    assert html =~ "-2"
    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(100))

    html = render_submit(element(view, "#commit-form"))

    assert html =~ "-2"
    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(98))
  end

  test "says so plainly when the count matched", %{conn: conn, box: box, lot: lot} do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "100"}})
    html = render_submit(element(view, "#commit-form"))

    assert html =~ "Toda linha contada conferiu"
    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(100))
  end

  test "a box that disagrees twice is flagged for the manager", %{
    conn: conn,
    box: box,
    lot: lot
  } do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "98"}})
    render_submit(element(view, "#recount-form"), %{"counts" => %{"#{lot.id}" => "97"}})
    html = render_submit(element(view, "#commit-form"))

    assert html =~ "sinalizada para o gestor"
    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(97))

    assert %{review_reason: "count_diverged_twice", notes: notes} = last_adjustment()
    assert notes =~ "contada duas vezes"
  end

  test "a recount that lands back on the ledger is not escalated", %{
    conn: conn,
    box: box,
    lot: lot
  } do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "98"}})
    render_submit(element(view, "#recount-form"), %{"counts" => %{"#{lot.id}" => "100"}})
    html = render_submit(element(view, "#commit-form"))

    refute text(html) =~ "sinalizada para o gestor"
    assert Decimal.equal?(Inventory.balance(box_id: box.id), Decimal.new(100))
  end

  defp last_adjustment do
    import Ecto.Query

    EstoqueOS.Inventory.Transaction
    |> where([t], t.type == "adjustment")
    |> order_by(desc: :id)
    |> limit(1)
    |> EstoqueOS.Repo.one!()
  end
end
