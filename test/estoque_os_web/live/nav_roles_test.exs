defmodule EstoqueOSWeb.NavRolesTest do
  @moduledoc """
  The menu shows a role only what that role may open. The router is the gate and
  the menu is presentation, so every menu entry is opened by every role and the
  router's answer must match what the menu predicted.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EstoqueOS.Accounts.Scope
  alias EstoqueOS.Accounts.User
  alias EstoqueOSWeb.Layouts

  # Gathered from the menu itself, not a copy: a new nav entry must fail here.
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

    # The logistics operator is a partner outside the ONG and never sees prices.
    refute html =~ ~s(href="/invoices")
    refute html =~ ~s(href="/issue")

    assert html =~ ~s(href="/conferences")
    assert html =~ ~s(href="/load-out")
    assert html =~ ~s(href="/returns")
  end

  # A spreadsheet import writes counts for the whole warehouse at once: a planning act.
  test "importing data belongs to the admin and the manager", %{conn: conn} do
    for role <- ~w(admin manager) do
      assert Layouts.may_access?(scope_for(role), "/stock/sheets")
    end

    for role <- ~w(logistics auditor) do
      refute Layouts.may_access?(scope_for(role), "/stock/sheets")
    end

    %{conn: conn} = register_and_log_in_logistics(%{conn: conn})
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ ~s(href="/stock/sheets")

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/stock/sheets")
  end

  test "the auditor keeps a menu worth opening", %{conn: conn} do
    %{conn: conn} = register_and_log_in_as(%{conn: conn}, "auditor")
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/invoices")
    assert html =~ ~s(href="/stock")
    assert html =~ ~s(href="/reports/audit")

    refute html =~ ~s(href="/entry")
    refute html =~ ~s(href="/load-out")
  end

  test "a group with nothing in it does not appear", %{conn: conn} do
    %{conn: conn} = register_and_log_in_as(%{conn: conn}, "auditor")
    {:ok, _view, html} = live(conn, ~p"/")

    for group <- Layouts.visible_groups(scope_for("auditor")) do
      assert group.items != []
      assert html =~ group.label
    end
  end
end
