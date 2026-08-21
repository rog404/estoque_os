defmodule EstoqueOSWeb.UserLive.SettingsTest do
  use EstoqueOSWeb.ConnCase, async: true

  alias EstoqueOS.Accounts
  import Phoenix.LiveViewTest
  import EstoqueOS.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Alterar e-mail"
      assert html =~ ~s(id="password_form")
    end

    # The screen requires sudo mode to render, but the form posts to a
    # controller, and a controller is reachable without ever rendering it.
    test "posting a new password without sudo mode is refused", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        )
        |> post(~p"/users/update-password", %{
          "user" => %{
            "password" => "uma senha nova bem longa",
            "password_confirmation" => "uma senha nova bem longa"
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permissão"
      refute Accounts.get_user_by_email_and_password(user.email, "uma senha nova bem longa")
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "Você precisa entrar para acessar esta página."} = flash
    end

    # This used to redirect to the login page, and it was reported as a bug —
    # ten minutes after signing in, "Configurações" answered with a login form
    # while every other screen still worked, so the app looked like it had
    # forgotten you at random. Nothing here is secret: it is your own address
    # and two empty forms.
    test "opens after the sudo window, with the changes held back", %{conn: conn} do
      old =
        DateTime.utc_now(:second) |> DateTime.add(-25, :minute)

      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: old)
        |> live(~p"/users/settings")

      assert html =~ "Configurações da conta"
      assert html =~ "precisa de uma entrada recente"

      # The buttons are there and disabled, which is how every other guarded
      # control in this app behaves.
      assert html =~ "disabled"
    end

    # The other half of the same bug: the window could lapse between opening the
    # screen and pressing the button, and `true = sudo_mode?(user)` raised a
    # MatchError. A crashed LiveView explains nothing to somebody who just typed
    # a password.
    test "refuses the change instead of crashing when the window has lapsed", %{conn: conn} do
      old = DateTime.utc_now(:second) |> DateTime.add(-25, :minute)

      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: old)
        |> live(~p"/users/settings")

      html =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "nova-senha-longa-123",
            "password_confirmation" => "nova-senha-longa-123"
          }
        })
        |> render_submit()

      assert html =~ "Saia e entre de novo"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "Enviamos um link para o novo endereço"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Alterar e-mail"
      assert result =~ "precisa ter o sinal @ e nenhum espaço"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Alterar e-mail"
      assert result =~ "não foi alterado"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "E-mail alterado com sucesso."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "O link de alteração de e-mail é inválido ou expirou."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "O link de alteração de e-mail é inválido ou expirou."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "Você precisa entrar para acessar esta página."
    end
  end
end
