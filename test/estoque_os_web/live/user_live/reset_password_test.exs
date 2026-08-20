defmodule EstoqueOSWeb.UserLive.ResetPasswordTest do
  use EstoqueOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EstoqueOS.AccountsFixtures

  alias EstoqueOS.{Accounts, Repo}
  alias EstoqueOS.Accounts.UserToken

  describe "request (:new)" do
    test "sends the same generic flash whether or not the email exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, _lv, html_known} =
        lv
        |> form("#reset_password_form", %{"user" => %{"email" => user.email}})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, _lv, html_unknown} =
        lv
        |> form("#reset_password_form", %{"user" => %{"email" => unique_user_email()}})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html_known =~ "Se o seu e-mail estiver cadastrado"
      assert html_unknown =~ "Se o seu e-mail estiver cadastrado"
    end

    test "delivers a reset_password-context token to an existing user", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      lv
      |> form("#reset_password_form", %{"user" => %{"email" => user.email}})
      |> render_submit()

      assert Repo.get_by(UserToken, user_id: user.id, context: "reset_password")
    end
  end

  describe "consume token (:edit)" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "sets a new password and logs the user in", %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      new_password = valid_user_password()

      form =
        form(lv, "#reset_password_edit_form", %{
          "user" => %{"password" => new_password, "password_confirmation" => new_password}
        })

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "a token already consumed by another tab is refused, not re-accepted", %{token: token} do
      # Both tabs load the page while the token is still good.
      {:ok, lv1, _html} = live(build_conn(), ~p"/users/reset-password/#{token}")
      {:ok, lv2, _html} = live(build_conn(), ~p"/users/reset-password/#{token}")

      password = valid_user_password()
      user_params = %{"password" => password, "password_confirmation" => password}

      form1 = form(lv1, "#reset_password_edit_form", %{"user" => user_params})
      render_submit(form1)
      conn1 = follow_trigger_action(form1, build_conn())
      assert get_session(conn1, :user_token)

      # Tab B submits the same, now-spent token.
      form2 = form(lv2, "#reset_password_edit_form", %{"user" => user_params})
      render_submit(form2)
      conn2 = follow_trigger_action(form2, build_conn())

      assert redirected_to(conn2) == ~p"/users/log-in"
      refute get_session(conn2, :user_token)
    end

    test "an invalid token redirects to log in", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/users/reset-password/invalid-token")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "O link é inválido ou expirou"
    end

    test "an expired token redirects to log in", %{conn: conn, user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      {:ok, _lv, html} =
        live(conn, ~p"/users/reset-password/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "O link é inválido ou expirou"
      assert Accounts.get_user!(user.id).hashed_password == user.hashed_password
    end
  end
end
