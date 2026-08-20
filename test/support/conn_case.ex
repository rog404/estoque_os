defmodule EstoqueOSWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use EstoqueOSWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint EstoqueOSWeb.Endpoint

      use EstoqueOSWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import EstoqueOSWeb.ConnCase
    end
  end

  setup tags do
    EstoqueOS.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Signs in a manager: the coordinator, who writes to the ledger and sees money.

  Accounts default to `auditor`, so a test that exercises an operational screen
  has to say so — which is the point of the role gate.
  """
  def register_and_log_in_operator(%{conn: _conn} = context) do
    register_and_log_in_as(context, "manager")
  end

  @doc """
  Signs in the logistics operator: handles the boxes, never sees a price.
  """
  def register_and_log_in_logistics(%{conn: _conn} = context) do
    register_and_log_in_as(context, "logistics")
  end

  @doc """
  Signs in an admin: everything, plus who else gets an account.
  """
  def register_and_log_in_admin(%{conn: _conn} = context) do
    register_and_log_in_as(context, "admin")
  end

  @doc "Signs in a user with the given role."
  def register_and_log_in_as(%{conn: _conn} = context, role) do
    context = register_and_log_in_user(context)

    {:ok, user} =
      context.user
      |> EstoqueOS.Accounts.User.role_changeset(%{role: role})
      |> EstoqueOS.Repo.update()

    %{context | user: user}
  end

  def register_and_log_in_user(%{conn: conn} = context) do
    user = EstoqueOS.AccountsFixtures.user_fixture()
    scope = EstoqueOS.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = EstoqueOS.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    EstoqueOS.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
