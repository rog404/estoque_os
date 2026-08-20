defmodule EstoqueOSWeb.UserSessionController do
  use EstoqueOSWeb, :controller

  alias EstoqueOS.Accounts
  alias EstoqueOS.Accounts.LoginThrottle
  alias EstoqueOSWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, gettext("User confirmed successfully."))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    keys = throttle_keys(conn, email)

    case LoginThrottle.check(keys) do
      {:error, seconds} ->
        # Answered before the password is even checked, so a guesser learns
        # nothing from how long the response took.
        conn
        |> put_flash(:error, wait_message(seconds))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      :ok ->
        attempt(conn, user_params, email, password, keys, info)
    end
  end

  defp attempt(conn, user_params, email, password, keys, info) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      LoginThrottle.clear(keys)

      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      LoginThrottle.record_failure(keys)

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, gettext("Invalid email or password"))
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # By email, because that is the account being guessed at. By address, because
  # otherwise a guesser walks down a list of emails and never trips the first.
  defp throttle_keys(conn, email) do
    [{:email, email}, {:address, conn.remote_ip |> :inet.ntoa() |> to_string()}]
  end

  defp wait_message(seconds) when seconds < 60 do
    gettext("Too many attempts. Try again in %{count} second(s).", count: seconds)
  end

  defp wait_message(seconds) do
    gettext("Too many attempts. Try again in %{count} minute(s).",
      count: div(seconds + 59, 60)
    )
  end

  # Completes the forced first-login/first-reset password change — the only
  # session state that reaches this action is `must_reset_password: true`
  # (the "required" page is the only thing that posts here). A stale or
  # double-submitted form after the flag already cleared is a real path here
  # (unlike the old sudo-mode gate this replaces), so it's refused with a
  # flash and a redirect, never a crash.
  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    if user.must_reset_password do
      case Accounts.update_user_password(user, user_params) do
        {:ok, {updated_user, expired_tokens}} ->
          UserAuth.disconnect_sessions(expired_tokens)

          conn
          |> put_flash(:info, gettext("Password updated successfully!"))
          |> UserAuth.log_in_user(updated_user, user_params)

        {:error, %Ecto.Changeset{}} ->
          conn
          |> put_flash(:error, gettext("That password could not be saved."))
          |> redirect(to: ~p"/users/reset-password/required")
      end
    else
      conn
      |> put_flash(:error, gettext("You don't have permission to do that."))
      |> redirect(to: ~p"/")
    end
  end

  # Consumes a "esqueci minha senha" token: sets the new password and logs
  # the user in fresh, same shape as the magic-link path above.
  def create_from_reset_token(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.reset_user_password_by_token(token, user_params) do
      {:ok, {user, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)

        conn
        |> put_flash(:info, gettext("Password updated successfully!"))
        |> UserAuth.log_in_user(user, user_params)

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, gettext("That password could not be saved."))
        |> redirect(to: ~p"/users/reset-password/#{token}")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end
end
