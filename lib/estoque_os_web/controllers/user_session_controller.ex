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

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, gettext("Password updated successfully!"))
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end
end
