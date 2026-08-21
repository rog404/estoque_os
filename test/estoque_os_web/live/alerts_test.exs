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

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.{Alerts, Catalog, Inventory, Repo, Reports}
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

      assert html =~ ~s(aria-label="O que precisa de atenção")
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

      scope = Scope.for_user(user)
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

  describe "who is shown the bell" do
    setup %{warehouse: warehouse, product: product} do
      diverged_count(warehouse, product)
      :ok
    end

    test "the manager and the admin are", %{conn: conn} do
      for log_in <- [&register_and_log_in_operator/1, &register_and_log_in_admin/1] do
        %{conn: conn} = log_in.(%{conn: conn})

        {:ok, _view, html} = live(conn, ~p"/")

        assert html =~ ~s(aria-label="O que precisa de atenção")
      end
    end

    # A number nobody can close is a number people learn to walk past.
    test "the logistics operator and the auditor are not", %{conn: conn} do
      for log_in <- [&register_and_log_in_logistics/1, &register_and_log_in_user/1] do
        %{conn: conn} = log_in.(%{conn: conn})

        {:ok, _view, html} = live(conn, ~p"/")

        refute html =~ ~s(aria-label="O que precisa de atenção")
      end
    end

    test "an admin standing in the auditor's shoes stops seeing it", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      conn = post(conn, ~p"/users/view-as", %{"role" => "auditor"})

      {:ok, _view, html} = live(conn, ~p"/")

      # Which is the point of standing in the role: what that person sees, and
      # the auditor does not see this.
      refute html =~ ~s(aria-label="O que precisa de atenção")
    end
  end

  describe "where an alert lands" do
    test "the shortage alert opens the stock already filtered to it", %{
      conn: conn,
      warehouse: warehouse,
      product: product
    } do
      {:ok, product} = Catalog.update_product(product, %{min_stock_override: 100})
      lot = lot_fixture(%{product_id: product.id})

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: actor_id(),
          entries: [
            %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(10)}
          ]
        })

      %{conn: conn} = register_and_log_in_operator(%{conn: conn})

      assert %{path: path} =
               Enum.find(Alerts.pending(Scope.for_user(nil)), &(&1.kind == :below_minimum))

      assert path == "/stock?below_minimum=on"

      {:ok, _view, html} = live(conn, path)

      assert html =~ product.name
    end
  end
end
