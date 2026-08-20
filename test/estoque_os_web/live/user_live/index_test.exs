defmodule EstoqueOSWeb.UserLive.IndexTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EstoqueOS.Accounts

  describe "as admin" do
    setup :register_and_log_in_admin

    test "lists every user", %{conn: conn, user: admin} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ admin.email
    end

    test "creates a user with a temporary password, shown once", %{conn: conn} do
      email = "nova.pessoa@example.com"

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> form("#new-user", %{"email" => email, "role" => "logistics"})
        |> render_submit()

      assert html =~ email
      assert html =~ "Senha temporária de"

      user = Accounts.get_user_by_email(email)
      assert user.role == "logistics"
      assert user.must_reset_password
      assert user.confirmed_at
    end

    test "refuses a duplicate email", %{conn: conn, user: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> form("#new-user", %{"email" => admin.email, "role" => "auditor"})
        |> render_submit()

      assert html =~ "alert-error"
    end
  end

  describe "as anyone else" do
    setup :register_and_log_in_operator

    test "is redirected away", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/users")
      assert to == ~p"/"
    end
  end

  describe "as an admin viewing as another role" do
    setup :register_and_log_in_admin

    test "is redirected away while borrowing the role", %{conn: conn} do
      conn = post(conn, ~p"/users/view-as?role=manager")

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/users")
      assert to == ~p"/"
    end
  end
end
