defmodule EstoqueOSWeb.AlertsTest do
  @moduledoc """
  What is open, and closing the two things that can be closed.

  A count that disagreed twice and a lot that arrived with no number are both
  correct to raise and both sometimes simply the answer. Without a way to accept
  one, the list only grows — and a list that only grows stops being read, which
  costs exactly the alarms that mattered.

  Accepting is not erasing: `review_reason` and `needs_review` stay true, and
  the acknowledgement is recorded beside them with a name and a date.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.{Alerts, Inventory, Repo, Reports}
  alias EstoqueOS.Inventory.{Lot, Transaction}

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    product = product_fixture(%{name: "Compressa de gaze"})

    %{warehouse: warehouse, product: product}
  end

  defp diverged_count(warehouse, product) do
    lot = lot_fixture(%{product_id: product.id})

    {:ok, transaction} =
      Inventory.post_transaction(%{
        type: "adjustment",
        reason_code: "count_correction",
        review_reason: "count_diverged_twice",
        user_id: actor_id(),
        entries: [
          %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(-3)}
        ]
      })

    transaction
  end

  defp lot_without_number(product) do
    lot_fixture(%{product_id: product.id, lot_number: nil, needs_review: true})
  end

  describe "the bell" do
    setup :register_and_log_in_operator

    test "carries the number of things open", %{
      conn: conn,
      warehouse: warehouse,
      product: product
    } do
      diverged_count(warehouse, product)
      lot_without_number(product)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "O que precisa de atenção"
      assert html =~ "Contagens que não bateram"
      assert html =~ "Mercadoria sem dados de lote"
    end

    test "says so when nothing is open", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Nada em aberto"
    end
  end

  describe "acknowledging a divergent count" do
    setup :register_and_log_in_operator

    test "closes the alert and keeps the record", %{
      conn: conn,
      warehouse: warehouse,
      product: product
    } do
      transaction = diverged_count(warehouse, product)

      assert Reports.counts_needing_review() != []

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_click(view, "acknowledge_count", %{"id" => "#{transaction.id}"})

      assert html =~ "Ciente"
      assert Reports.counts_needing_review() == []

      reloaded = Repo.get!(Transaction, transaction.id)

      # The alert is closed. What raised it is not erased — an auditor asking
      # what happened here still finds the divergence, and now also finds who
      # accepted it.
      assert reloaded.review_reason == "count_diverged_twice"
      assert reloaded.review_acknowledged_at
      assert reloaded.review_acknowledged_by_id
    end
  end

  describe "acknowledging a lot with no number" do
    setup :register_and_log_in_operator

    test "closes the alert and keeps the flag", %{conn: conn, product: product} do
      lot = lot_without_number(product)

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(
        element(view, ~s(button[phx-value-id="#{lot.id}"][phx-click="acknowledge_lot"]))
      )

      reloaded = Repo.get!(Lot, lot.id)

      assert reloaded.needs_review
      assert reloaded.review_acknowledged_at
      assert Repo.aggregate(Alerts.open_lots(), :count) == 0
    end
  end

  describe "who may close one" do
    test "the logistics operator may not — it is not the counter's call", %{
      conn: conn,
      warehouse: warehouse,
      product: product
    } do
      transaction = diverged_count(warehouse, product)
      %{conn: conn, user: user} = register_and_log_in_logistics(%{conn: conn})

      scope = EstoqueOS.Accounts.Scope.for_user(user)
      refute Alerts.may_acknowledge?(scope)

      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "acknowledge_count"

      # And the refusal is in the context, not in the absent button.
      assert {:error, :not_allowed} = Alerts.acknowledge_count(transaction.id, scope)
    end

    test "an admin wearing somebody else's role may not either", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      conn = post(conn, ~p"/users/view-as", %{"role" => "manager"})

      {:ok, _view, html} = live(conn, ~p"/")

      # An acknowledgement carries a name, and it has to be the name of whoever
      # actually looked.
      refute html =~ "acknowledge_lot"
    end
  end
end
