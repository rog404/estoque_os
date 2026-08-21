defmodule EstoqueOSWeb.ViewAsTest do
  @moduledoc """
  An admin standing in another role's shoes.

  Roles now decide two different things — what may be changed and what may be
  seen — and the second is invisible from the inside. This is how an admin finds
  out whether the logistics operator's stock screen still shows a price, without
  keeping four accounts and a private window.

  The properties that make it safe to have at all are the ones under test: a
  role and never a person, read-only whatever the role allows, and never upward.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.Transaction
  alias EstoqueOS.Repo

  setup %{conn: conn} do
    warehouse = EstoqueOS.Inventory.Locations.default_location() || location_fixture()
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

    # This used to refuse the *page*, and that was the wrong door to shut.
    # "Ver como" existed to answer "what does this person see", and the screens
    # a role actually works in are most of the answer — an admin who borrowed
    # the logistics role got the overview and then "você não tem permissão" on
    # everything else, which reads as a broken app rather than as a role.
    #
    # So the page opens and the *write* is what is refused, by the same hook
    # that already refuses one on any read-only screen.
    test "walks into a writing screen while wearing another role", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})

      assert {:ok, _view, html} = live(conn, ~p"/load-out")
      assert html =~ "Enviar carga"

      assert {:ok, _view, html} = live(conn, ~p"/entry")
      assert html =~ "Entrada manual"
    end

    # Every transaction records who made it, and one made under a borrowed role
    # would name the wrong role. `operator?/1` is what says no, and it says no on
    # the screens the role works in exactly as it does on the stock list.
    #
    # One test over the screens rather than one test per screen: three copies of
    # this said the same sentence about three paths, and the third would have
    # been forgotten the day a fourth screen appeared. The event is sent
    # straight at the socket because that is how a write would actually be
    # attempted — the button is not rendered, and a button nobody rendered has
    # never been what stops anything.
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
      # `/stock` is a screen every role may open, so the route gate has nothing
      # to say here and `operator?/1` is the only thing standing between a
      # borrowed role and a write. `require_role` had a second copy of this rule
      # for a while; it could never fire, because `require_operator` in the
      # pipeline already asks `operator?/1`, and an authorization guard that
      # cannot fire is worse than none — it reads like protection.
      conn = post(conn, ~p"/users/view-as", %{"role" => "manager"})

      {:ok, view, html} = live(conn, ~p"/stock")

      # Manager writes; an admin standing in that role does not.
      refute html =~ "phx-submit=\"import\""

      refute EstoqueOSWeb.UserAuth.operator?(
               :sys.get_state(view.pid).socket.assigns.current_scope
             )
    end

    # What the ONG actually asked for: "preciso poder NAVEGAR como se fosse um
    # operador logístico para ver tudo que ele pode ver". Before this, every
    # control keyed off one predicate and simply vanished, so the borrowed
    # screen was a hollow copy of the operator's — you could not tell a
    # permission you lack from a feature that is not there.
    test "sees the operator's controls, disabled, with the reason", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as", %{"role" => "logistics"})

      {:ok, _view, html} = live(conn, ~p"/boxes")

      # The screen is the operator's screen: the box-creating form is on it.
      assert html =~ ~s(id="new-box")

      # And nothing on it can be pressed. One `disabled` fieldset does that to
      # every control underneath, which is why the assertion is on the wrapper.
      gate = Regex.run(~r{<fieldset[^>]*>}, html) |> hd()
      assert gate =~ "disabled"
      assert gate =~ "outro papel"
    end

    test "the operator's controls are absent for a role that never had them", %{conn: conn} do
      # Not disabled — gone. The auditor does not write anywhere, so a greyed-out
      # box form on their screen would be describing a permission that does not
      # exist rather than one they are currently standing outside of.
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
