defmodule EstoqueOSWeb.NavRolesTest do
  @moduledoc """
  The menu shows a role only what that role may open.

  A menu entry that answers with "você não tem permissão para acessar esta
  página" is not information, it is a door with a wall behind it — reported by
  Rogerio on 2026-08-20, after the logistics operator spent a week being
  offered the invoices.

  The gate is still the router; the menu is presentation. Which means the two
  can drift, and this file is what stops them: every entry in the menu is
  opened by every role, and the answer the router gives has to be the answer
  the menu predicted.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Accounts.User
  alias EstoqueOSWeb.Layouts

  # Every path the menu offers, gathered from the menu itself rather than
  # listed again here: an entry added to the nav without a thought about roles
  # should fail this file, and it cannot do that if the list is a copy.
  defp menu_paths do
    ~w(admin manager marketing logistics auditor)
    |> Enum.flat_map(fn role ->
      %Scope{user: %User{role: role}}
      |> Layouts.visible_groups()
      |> Enum.flat_map(& &1.items)
      |> Enum.map(& &1.path)
    end)
    |> Enum.uniq()
  end

  defp scope_for(role), do: %Scope{user: %User{role: role}}

  for role <- ~w(admin manager marketing logistics auditor) do
    @role role

    test "the menu matches what the router allows for #{role}", %{conn: conn} do
      %{conn: conn} = register_and_log_in_as(%{conn: conn}, @role)
      scope = scope_for(@role)

      for path <- menu_paths() do
        offered? = Layouts.may_access?(scope, path)

        opens? =
          case live(conn, path) do
            {:ok, _view, _html} -> true
            {:error, {:live_redirect, %{to: "/"}}} -> false
            {:error, {:redirect, %{to: "/"}}} -> false
            other -> flunk("#{path} as #{@role} answered #{inspect(other)}")
          end

        assert offered? == opens?,
               """
               #{path} as #{@role}: the menu #{if offered?, do: "offers", else: "hides"} it \
               and the router #{if opens?, do: "opens", else: "refuses"} it.

               One of the two is wrong. The router is the gate, so it is usually \
               the `roles:` on the entry in `Layouts.nav_groups/0` that needs \
               fixing.
               """
      end
    end
  end

  test "the logistics operator is not offered the invoices or the write-off", %{conn: conn} do
    %{conn: conn} = register_and_log_in_logistics(%{conn: conn})
    {:ok, _view, html} = live(conn, ~p"/")

    # The prices are the point: this is a partner outside the ONG, and the
    # spreadsheet they return has always carried quantity and box and never
    # what anything cost.
    refute html =~ ~s(href="/invoices")
    refute html =~ ~s(href="/issue")

    # And their own work is all still there.
    assert html =~ ~s(href="/conferences")
    assert html =~ ~s(href="/load-out")
    assert html =~ ~s(href="/returns")
  end

  # Asked for by name: a spreadsheet import writes counts for the whole
  # warehouse at once, with no box in anyone's hands. That is a planning act.
  test "importing data belongs to the admin and the manager", %{conn: conn} do
    for role <- ~w(admin manager) do
      assert Layouts.may_access?(scope_for(role), "/reports/data")
    end

    for role <- ~w(logistics auditor) do
      refute Layouts.may_access?(scope_for(role), "/reports/data")
    end

    %{conn: conn} = register_and_log_in_logistics(%{conn: conn})
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ ~s(href="/reports/data")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/reports/data")
  end

  # The reader who writes nothing still has somewhere to be: hiding what a role
  # cannot open must not leave it with an empty bar.
  test "the auditor keeps a menu worth opening", %{conn: conn} do
    %{conn: conn} = register_and_log_in_as(%{conn: conn}, "auditor")
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/invoices")
    assert html =~ ~s(href="/stock")
    assert html =~ ~s(href="/reports/audit")

    # Nothing that writes.
    refute html =~ ~s(href="/entry")
    refute html =~ ~s(href="/load-out")
  end

  # An empty group is no group. The Entradas menu for a role that may reach
  # none of its entries used to be a heading with nothing under it.
  test "a group with nothing in it does not appear", %{conn: conn} do
    %{conn: conn} = register_and_log_in_as(%{conn: conn}, "auditor")
    {:ok, _view, html} = live(conn, ~p"/")

    for group <- Layouts.visible_groups(scope_for("auditor")) do
      assert group.items != []
      assert html =~ group.label
    end
  end
end
