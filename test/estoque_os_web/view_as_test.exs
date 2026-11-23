defmodule EstoqueOSWeb.ViewAsTest do
  @moduledoc """
  An admin standing in another role's shoes. The properties under test: a role
  and never a person, read-only whatever the role allows, and never upward.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Locations
  alias EstoqueOS.Inventory.Transaction
  alias EstoqueOS.Repo

  setup %{conn: conn} do
    warehouse = Locations.default_location() || location_fixture()
    box = box_fixture(%{location_id: warehouse.id})
    product = product_fixture(%{name: "Compressa de gaze"})
    lot = lot_fixture(%{product_id: product.id, expires_on: ~D[2029-01-31]})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: box.id,
            quantity: Decimal.new(10),
            unit_cost: Decimal.new("13.37")
          }
        ]
      })

    %{conn: conn}
  end

  describe "an admin" do
    setup context, do: register_and_log_in_as(context, "admin")

    test "sees prices as themselves", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")
      assert html =~ "13,37"
    end

    test "viewing as the logistics operator stops seeing prices", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})
      assert redirected_to(conn) == "/"

      {:ok, _view, html} = live(conn, ~p"/stock")

      refute html =~ "13,37"
      refute html =~ "Custo unitário"
      assert html =~ "Compressa de gaze"
    end

    test "viewing as the logistics operator is told so, on every page", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})
      {:ok, _view, html} = live(conn, ~p"/stock")

      assert html =~ "operador logístico"
      assert html =~ "Somente leitura"
    end

    # The page opens and the write is what is refused, by the same hook that
    # refuses one on any read-only screen.
    test "walks into a writing screen while wearing another role", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})

      assert {:ok, _view, html} = live(conn, ~p"/load-out")
      assert html =~ "Enviar carga"

      assert {:ok, _view, html} = live(conn, ~p"/entry")
      assert html =~ "Entrada manual"
    end

    # A transaction under a borrowed role would name the wrong role; `operator?/1`
    # refuses it. One test over all the screens, with the event sent straight at
    # the socket, since an unrendered button never stops anything.
    test "is refused the write on every screen it may now open", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "manager"})

      for {path, event} <- [
            {~p"/load-out", "send"},
            {~p"/entry", "enter"},
            {~p"/issue", "issue"}
          ] do
        {:ok, view, _html} = live(conn, path)
        before = Repo.aggregate(Transaction, :count)

        assert render_click(view, event, %{}) =~ "não tem permissão",
               "#{path} did not refuse #{event}"

        assert Repo.aggregate(Transaction, :count) == before,
               "#{path} wrote to the ledger under a borrowed role"
      end
    end

    test "is refused writes on a screen it is allowed to open", %{conn: conn} do
      # `/stock` is open to every role, so the route gate says nothing and
      # `operator?/1` alone stands between a borrowed role and a write.
      conn = post(conn, ~p"/users/view-as", %{"role" => "manager"})

      {:ok, view, html} = live(conn, ~p"/stock")

      refute html =~ "phx-submit=\"import\""

      refute EstoqueOSWeb.UserAuth.operator?(
               :sys.get_state(view.pid).socket.assigns.current_scope
             )
    end

    # The screen is the role's, button for button; the refusal happens on the event.
    test "sees the operator's controls exactly as the operator does", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})

      {:ok, _view, html} = live(conn, ~p"/boxes")

      assert html =~ ~s(id="new-box")

      gate = Regex.run(~r{<fieldset[^>]*>}, html) |> hd()
      refute gate =~ "disabled"
    end

    test "pressing a control says no and writes nothing", %{conn: conn} do
      warehouse = Locations.default_location()
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})

      {:ok, view, _html} = live(conn, ~p"/boxes")

      refused =
        render_hook(view, "create", %{"code" => "VA99", "location_id" => "#{warehouse.id}"})

      assert refused =~ "permissão"

      refute Enum.any?(
               Locations.list_boxes(warehouse.id),
               &(&1.code == "VA99")
             )
    end

    test "the operator's controls are absent for a role that never had them", %{conn: conn} do
      # Not disabled but gone: the auditor never writes, so a greyed-out form
      # would describe a permission that does not exist.
      conn = post(conn, ~p"/users/view-as", %{"role" => "auditor"})

      {:ok, _view, html} = live(conn, ~p"/boxes")

      refute html =~ ~s(id="new-box")
    end

    test "viewing as the auditor keeps the prices and drops the writing", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "auditor"})

      {:ok, _view, html} = live(conn, ~p"/stock")
      assert html =~ "13,37"

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/load-out")
    end

    test "goes back to being themselves", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})
      conn = delete(conn, ~p"/users/view-as")
      assert redirected_to(conn) == "/"

      {:ok, _view, html} = live(conn, ~p"/stock")
      assert html =~ "13,37"
    end

    test "cannot view as admin, because this only ever reduces", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "admin"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "não é um papel"
      refute get_session(conn, :view_as)
    end

    test "cannot view as a role that does not exist", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "superuser"})
      refute get_session(conn, :view_as)
    end
  end

  describe "anybody who is not an admin" do
    setup context, do: register_and_log_in_operator(context)

    test "cannot borrow a role", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permissão"
      refute get_session(conn, :view_as)
    end

    test "is not offered the picker", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/stock")
      refute html =~ "Ver como"
    end
  end
end
