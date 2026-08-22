defmodule EstoqueOSWeb.ViewAsParityTest do
  @moduledoc """
  Standing in a role's shoes has to *be* that role, minus the writing.

  The complaint this pins down: "acessar como" is supposed to give exactly the
  access of the person being tested, and anything less makes the feature a worse
  copy of the app rather than an answer to "what does this person see".

  So the audit is a comparison, not an opinion: for every borrowable role, the
  menu and the doors are asked twice — once of somebody who really is that role,
  once of an admin wearing it — and the two answers have to match. What differs
  is writing, in one direction only.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  alias EstoqueOS.Inventory
  alias EstoqueOS.Inventory.{Locations, Transaction}
  alias EstoqueOS.Repo

  @roles ~w(manager marketing logistics auditor)

  # Every screen the menu can reach, plus the ones it deliberately does not
  # link: a borrowed role must be stopped at the same doors, whichever way
  # somebody arrives at them.
  @paths ~w(
    / /stock /boxes /locations /kits /missions /conferences /load-out /returns
    /entry /entries /issue /issues /invoices /invoices/import
    /reports/sales /reports/transit /reports/audit /reports/data /admin/users
  )

  setup do
    warehouse = location_fixture(%{name: "Estoque Principal", kind: "warehouse"})
    location_fixture(%{name: "Trânsito", kind: "transit"})
    box = box_fixture(%{code: "PA01", location_id: warehouse.id})
    product = product_fixture(%{name: "Compressa de gaze 7,5x7,5"})
    lot = lot_fixture(%{product_id: product.id})

    {:ok, _} =
      Inventory.post_transaction(%{
        type: "purchase_in",
        user_id: actor_id(),
        entries: [
          %{
            lot_id: lot.id,
            location_id: warehouse.id,
            box_id: box.id,
            quantity: Decimal.new(50),
            unit_cost: Decimal.new("1.20")
          }
        ]
      })

    %{warehouse: warehouse, box: box, product: product}
  end

  defp as_role(role) do
    %{conn: build_conn()} |> register_and_log_in_as(role) |> Map.fetch!(:conn)
  end

  defp as_admin_viewing(role) do
    conn = %{conn: build_conn()} |> register_and_log_in_as("admin") |> Map.fetch!(:conn)

    # `recycle/1` keeps the cookies, which is where the borrowed role lives.
    conn |> post(~p"/users/view-as", %{"role" => role}) |> recycle()
  end

  defp doors(conn) do
    Map.new(@paths, fn path ->
      answer =
        case live(conn, path) do
          {:ok, _view, _html} -> :open
          {:error, {:redirect, _}} -> :closed
          {:error, {:live_redirect, _}} -> :closed
        end

      {path, answer}
    end)
  end

  defp menu_paths(conn) do
    {:ok, _view, html} = live(conn, ~p"/")

    ~r/href="(\/[^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.reject(&String.starts_with?(&1, "/users/"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The `disabled` attribute on the gate that wraps a screen's controls. Two
  # screens are compared by it because that is the difference the operation
  # complained about: a borrowed role was looking at a greyed-out app.
  defp gate_disabled?(conn, path) do
    {:ok, _view, html} = live(conn, path)

    case Regex.run(~r{<fieldset[^>]*>}, html) do
      nil -> :no_gate
      [gate] -> gate =~ "disabled"
    end
  end

  describe "the doors" do
    test "open and close the same way for every borrowable role" do
      for role <- @roles do
        assert doors(as_admin_viewing(role)) == doors(as_role(role)),
               "borrowing #{role} does not reach the same screens as being #{role}"
      end
    end
  end

  describe "the menu" do
    test "lists the same entries for every borrowable role" do
      for role <- @roles do
        assert menu_paths(as_admin_viewing(role)) == menu_paths(as_role(role)),
               "the menu while borrowing #{role} is not the menu #{role} sees"
      end
    end
  end

  describe "the screen" do
    test "looks the same as the role's own, controls included" do
      for role <- @roles do
        assert gate_disabled?(as_admin_viewing(role), ~p"/boxes") ==
                 gate_disabled?(as_role(role), ~p"/boxes"),
               "the boxes screen while borrowing #{role} is not shaped like #{role}'s"
      end
    end
  end

  describe "writing" do
    # The one difference, and the direction matters: what a role can do, a
    # borrowed role can only look at. Every transaction records who made it, and
    # a ledger that misattributes is worse than no ledger.
    test "is refused where the role would have written", %{box: box, warehouse: warehouse} do
      conn = as_admin_viewing("logistics")
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      elsewhere = location_fixture(%{name: "Missão Tefé", kind: "mission_site"})

      assert render_hook(view, "move", %{"location_id" => "#{elsewhere.id}"}) =~ "permissão"
      assert Locations.get_box!(box.id).location_id == warehouse.id
    end

    test "is refused on the count that stamps a box", %{box: box} do
      conn = as_admin_viewing("logistics")
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      assert render_hook(view, "verify", %{}) =~ "permissão"
      assert is_nil(Locations.get_box!(box.id).last_verified_at)
    end

    # Picking a product and previewing FEFO are reads, and they stay open — that
    # is what makes the borrowed screen worth looking at. What is refused is the
    # act.
    test "is refused on a write-off", %{product: product} do
      conn = as_admin_viewing("manager")
      {:ok, view, _html} = live(conn, ~p"/issue")

      render_hook(view, "pick", %{"product" => "#{product.id}"})
      refused = render_hook(view, "issue", %{})

      assert refused =~ "permissão"
      assert Repo.aggregate(from(t in Transaction, where: t.type == "manual_out"), :count) == 0
    end

    # Never upward: the borrowed role cannot be admin, and the picker is not
    # offered while already wearing somebody else's shoes.
    test "cannot be used to become an admin" do
      conn = as_admin_viewing("auditor")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/users")

      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ ~s(/users/view-as?role=manager)
    end
  end
end
