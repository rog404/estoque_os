defmodule EstoqueOS.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias EstoqueOS.Repo

  alias EstoqueOS.Accounts.{User, UserNotifier, UserToken}

  @doc """
  Whether this installation can send email. Off by default: accounts are
  handed out by an admin, so nothing depends on a message arriving.

  Email-only flows (magic link, password reset, confirming a changed address)
  are gated on this in the router and the screens.
  """
  def email_enabled?, do: Application.get_env(:estoque_os, :email_enabled, false)

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Registers a user.
  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Provisions an account: an admin vouches for email and role and hands over a
  temporary password. There is no self-service sign-up.

  Created pre-confirmed and flagged `must_reset_password: true`, so the first
  session must set a real password (`EstoqueOSWeb.UserAuth`'s
  `:require_password_not_pending` gate). Insert, password and role commit
  together, so a crash never leaves an account without a password.

  Pass `:password` in `opts` to set one; otherwise one is generated and
  returned alongside the user, to be shown once.
  """
  def create_user_with_temporary_password(email, role, opts \\ []) do
    password = Keyword.get_lazy(opts, :password, &random_password/0)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.email_changeset(%User{}, %{email: email}))
    |> Ecto.Multi.update(:with_password, fn %{user: user} ->
      user
      |> User.password_changeset(%{password: password, password_confirmation: password})
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      |> Ecto.Changeset.put_change(:must_reset_password, true)
    end)
    |> Ecto.Multi.update(:with_role, fn %{with_password: user} ->
      User.role_changeset(user, %{role: role})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{with_role: user}} -> {:ok, {user, password}}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp random_password, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64()

  @doc """
  Whether the last authentication was within the limit (default 20 minutes).
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `EstoqueOS.Accounts.User.email_changeset/3` for a list of supported options.
  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `EstoqueOS.Accounts.User.password_changeset/3` for a list of supported options.
  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.
  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Changes what a user is allowed to do. Roles are granted deliberately; there
  is no self-service path to a role that can write to the ledger.
  """
  def update_user_role(%User{} = user, role) do
    user
    |> User.role_changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Every account, for the admin screen that provisions them.
  """
  def list_users do
    Repo.all(from u in User, order_by: [asc: u.email])
  end

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  A confirmed user is logged in and the link expires. An unconfirmed user with
  no password is confirmed and all tokens are expired. An unconfirmed user
  with a password raises (session fixation risk).
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Delivers the update email instructions to the given user.
  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Delivers password reset instructions to the given user.
  """
  def deliver_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)

    UserNotifier.deliver_reset_password_instructions(
      user,
      reset_password_url_fun.(encoded_token)
    )
  end

  @doc """
  Gets the user with the given password reset token, or `nil`.
  """
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Consumes a password reset token and sets the new password in one step.

  Re-verifies the token at submission time, so a token already spent in one
  tab is refused in another. Returns `{:error, :invalid_token}` when missing,
  used or expired; otherwise the shape of `update_user_password/2`.
  """
  def reset_user_password_by_token(token, attrs) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
           {user, _token} <- Repo.one(query) do
        update_user_password(user, attrs)
      else
        _ -> {:error, :invalid_token}
      end
    end)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
