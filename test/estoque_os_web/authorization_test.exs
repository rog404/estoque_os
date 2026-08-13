defmodule EstoqueOSWeb.AuthorizationTest do
  @moduledoc """
  The roles were declared and never enforced: `require_role` existed in
  `user_auth.ex` and appeared in no route, so a viewer could send a mission's
  supplies out of the warehouse. These tests are the enforcement.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.DataCase, only: [errors_on: 1]
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory

  @writes ~w(/invoices/import /audit /issue /returns /load-out)
  @reads ~w(/ /stock /boxes /locations /kits /invoices /issues /reports/audit)

  describe "a viewer" do
    setup :register_and_log_in_user

    test "may read every screen that only reports", %{conn: conn} do
      for path <- @reads do
        assert {:ok, _view, _html} = live(conn, path), "viewer was blocked from #{path}"
      end
    end

    test "may not reach any screen that writes to the ledger", %{conn: conn} do
      for path <- @writes do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
                 live(conn, path),
               "viewer reached #{path}"

        assert message =~ "permissão"
      end
    end

    test "may not export the valued stock", %{conn: conn} do
      conn = get(conn, ~p"/stock/export.xlsx")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permissão"
    end

    # The stock screen reports to everyone, so its own route cannot be the gate.
    # It carried a spreadsheet import that posts adjustments, reachable by
    # anyone who could read the page.
    test "is not offered the spreadsheet on the stock screen", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      refute html =~ "import-form"
    end

    test "may not import a count even by sending the event straight up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/stock")

      assert render_hook(view, "import", %{}) =~ "permissão"
    end
  end

  describe "an operator" do
    setup :register_and_log_in_operator

    test "reaches every operational screen", %{conn: conn} do
      for path <- @writes do
        assert {:ok, _view, _html} = live(conn, path), "operator was blocked from #{path}"
      end
    end

    test "exports the stock", %{conn: conn} do
      conn = get(conn, ~p"/stock/export.xlsx")

      assert response_content_type(conn, :xlsx) =~ "spreadsheetml"
    end

    # Pairs with the viewer's `refute`: without this, renaming the form would
    # make that test pass while proving nothing.
    test "is offered the spreadsheet on the stock screen", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ "import-form"
    end
  end

  describe "public surface" do
    test "there is no way to sign yourself up", %{conn: conn} do
      # Registration was open, defaulted to a writing role, and confirmed
      # itself by magic link: an account with write access for anyone.
      conn = get(conn, "/users/register")
      assert conn.status == 404
    end

    test "the login page says where accounts come from", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ "Contas são criadas por um administrador"
    end
  end

  describe "ledger attribution" do
    test "a movement without an author is refused" do
      warehouse = location_fixture(%{kind: "warehouse"})
      lot = lot_fixture()

      assert {:error, changeset} =
               Inventory.post_transaction(%{
                 type: "purchase_in",
                 entries: [
                   %{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(10)}
                 ]
               })

      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "a user who moved stock cannot be deleted out of the record" do
      warehouse = location_fixture(%{kind: "warehouse"})
      lot = lot_fixture()
      user_id = actor_id()

      {:ok, _} =
        Inventory.post_transaction(%{
          type: "purchase_in",
          user_id: user_id,
          entries: [%{lot_id: lot.id, location_id: warehouse.id, quantity: Decimal.new(10)}]
        })

      # on_delete: :restrict — the alternative was nilify_all, which quietly
      # erased who took the controlled substance out.
      assert_raise Ecto.ConstraintError, fn ->
        EstoqueOS.Repo.delete!(EstoqueOS.Repo.get!(EstoqueOS.Accounts.User, user_id))
      end
    end
  end
end
