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
        # Answered before the password check, so timing leaks nothing.
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

      # Don't disclose whether the email is registered (user enumeration).
      conn
      |> put_flash(:error, gettext("Invalid email or password"))
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # By address too, or a guesser walking a list of emails never trips one key.
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

  # Two gates: `must_reset_password` for the forced change (sudo mode is beside
  # the point there), sudo mode for the ordinary one. Sudo stops a borrowed
  # session from locking the owner out, and with no mailer there is no recovery.
  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user
    forced? = user.must_reset_password

    if forced? or Accounts.sudo_mode?(user) do
      case Accounts.update_user_password(user, user_params) do
        {:ok, {updated_user, expired_tokens}} ->
          UserAuth.disconnect_sessions(expired_tokens)

          conn
          |> put_flash(:info, gettext("Password updated successfully!"))
          |> UserAuth.log_in_user(updated_user, user_params)

        {:error, %Ecto.Changeset{}} ->
          back_to = if forced?, do: ~p"/users/reset-password/required", else: ~p"/users/settings"

          conn
          |> put_flash(:error, gettext("That password could not be saved."))
          |> redirect(to: back_to)
      end
    else
      conn
      |> put_flash(:error, gettext("You don't have permission to do that."))
      |> redirect(to: ~p"/")
    end
  end

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
