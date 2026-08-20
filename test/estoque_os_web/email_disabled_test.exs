defmodule EstoqueOSWeb.EmailDisabledTest do
  @moduledoc """
  Production runs without a mailer, so the flows that need one must say so
  rather than hand over a form that leads nowhere.

  `async: false` and the flag flipped for real: `email_enabled?/0` reads
  application env, which is global, and a concurrent test reading it mid-flip
  would see the wrong installation.
  """

  use EstoqueOSWeb.ConnCase, async: false

  import EstoqueOS.AccountsFixtures
  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:estoque_os, :email_enabled, false)
    on_exit(fn -> Application.put_env(:estoque_os, :email_enabled, true) end)
    :ok
  end

  # The whole point of the gate is that nothing on the way in depends on a
  # message arriving.
  test "the login page keeps the password form and drops the magic link", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    assert html =~ ~s(id="login_form_password")
    refute html =~ ~s(id="login_form_magic")
  end

  test "the login page says who to ask instead of linking a dead reset", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    refute html =~ ~s(href="/users/reset-password")
    assert text(html) =~ "Fale com um administrador"
  end

  test "asking for a reset link lands back on the login page with a reason", %{conn: conn} do
    assert {:error, {:redirect, %{to: path, flash: flash}}} =
             live(conn, ~p"/users/reset-password")

    assert path == ~p"/users/log-in"
    assert flash["error"] =~ "não envia e-mail"
  end

  test "a magic-link token is not a way in", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/users/log-in/some-token")
    assert path == ~p"/users/log-in"
  end

  test "posting a reset token is refused before it reaches the controller", %{conn: conn} do
    conn = post(conn, ~p"/users/reset-password/some-token", %{"user" => %{"password" => "x"}})

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  # The one flow that still has to work, because it is the only one left.
  test "an account can still change its own password", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/users/settings")

    refute html =~ ~s(id="email_form")
    assert html =~ ~s(id="password_form")

    new_password = valid_user_password() <> "-novo"

    form =
      form(lv, "#password_form", %{
        "user" => %{"password" => new_password, "password_confirmation" => new_password}
      })

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/"
    assert EstoqueOS.Accounts.get_user_by_email_and_password(user.email, new_password)
  end

  # `refute html =~ "..."` matches markup as readily as text; strip the tags
  # first when the claim is about what a person reads.
  defp text(html), do: String.replace(html, ~r{<[^>]*>}s, " ")
end
