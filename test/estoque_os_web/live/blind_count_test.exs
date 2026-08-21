defmodule EstoqueOSWeb.BlindCountTest do
  @moduledoc """
  Shown the expected number, a person counting a hundred gauzes finds ninety-eight
  and writes a hundred — not dishonestly, but because the eye stops when it
  reaches the answer it was given. A count that confirms the ledger it was copied
  from measures nothing.

  So the expected quantity must be absent while counting and present afterwards,
  and both halves are pinned here: a test that only checked the second half would
  pass on the screen this replaced.
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

  test "does not reveal the expected quantity while counting", %{conn: conn, box: box} do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    # Scoped to the sheet itself: the page chrome is full of "100" in class names
    # like bg-base-100, and a page-wide refute would fail on the nav.
    sheet = view |> element("#count-form") |> render()

    assert sheet =~ "Gaze estéril"
    assert sheet =~ "L-777"

    # It lists the lot to be counted and withholds the number.
    refute sheet =~ "100"
    refute sheet =~ "presume"
  end

  # A count that disagrees is now counted a second time before anything is
  # written — and the recount names the item without ever saying by how much it
  # was off, or the second count would be as compromised as a sighted first one.
  test "asks for a recount without saying how far off it was", %{
    conn: conn,
    box: box,
    lot: lot
  } do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "98"}})

    sheet = view |> element("#recount-form") |> render()

    assert sheet =~ "Gaze estéril"
    refute sheet =~ "100"

    # Read as the counter reads it: "-2" also lives inside the class `w-28`,
    # and matching that would let this test pass on a screen that leaked.
    refute String.replace(sheet, ~r{<[^>]*>}s, " ") =~ "-2"

    # And nothing has been written.
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

    # The confirmation is where the numbers finally meet — before the write.
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

    # Agreeing with the ledger skips the recount: there is nothing to settle.
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

  # The second count agreeing with the ledger is the happy ending: the first
  # count was simply wrong, and nobody needs telling.
  test "a recount that lands back on the ledger is not escalated", %{
    conn: conn,
    box: box,
    lot: lot
  } do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}/count")

    render_submit(element(view, "#count-form"), %{"counts" => %{"#{lot.id}" => "98"}})
    render_submit(element(view, "#recount-form"), %{"counts" => %{"#{lot.id}" => "100"}})
    html = render_submit(element(view, "#commit-form"))

    refute html =~ "sinalizada para o gestor"
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
