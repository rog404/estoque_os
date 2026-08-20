defmodule EstoqueOSWeb.RequirePasswordNotPendingTest do
  @moduledoc """
  The concrete risk named in the plan: if `:require_password_not_pending`
  ever ends up on the on_mount list of `UserLive.ResetPassword, :required`
  itself (a copy-paste from another live_session), a flagged user gets
  redirected to the very page meant to clear the flag, forever. This
  asserts the required page renders instead of redirecting.
  """

  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.AccountsFixtures

  alias EstoqueOS.Accounts

  setup do
    user = user_fixture() |> set_password()
    {:ok, user} = flag_for_reset(user)
    %{conn: log_in_user(build_conn(), user), user: user}
  end

  test "the required page itself renders for a flagged user, not another redirect", %{conn: conn} do
    assert {:ok, _lv, html} = live(conn, ~p"/users/reset-password/required")
    assert html =~ "temporária"
  end

  test "every other protected route redirects a flagged user to the required page", %{conn: conn} do
    for path <- [~p"/", ~p"/stock", ~p"/kits", ~p"/users/settings"] do
      assert {:error, {:redirect, %{to: to}}} = live(conn, path)
      assert to == ~p"/users/reset-password/required"
    end
  end

  test "completing the required change clears the flag and unblocks the app", %{
    conn: conn,
    user: user
  } do
    {:ok, lv, _html} = live(conn, ~p"/users/reset-password/required")

    new_password = valid_user_password()

    form =
      form(lv, "#reset_password_required_form", %{
        "user" => %{"password" => new_password, "password_confirmation" => new_password}
      })

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/"
    refute Accounts.get_user!(user.id).must_reset_password
  end

  defp flag_for_reset(user) do
    user
    |> Ecto.Changeset.change(must_reset_password: true)
    |> EstoqueOS.Repo.update()
  end
end
