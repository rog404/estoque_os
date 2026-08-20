defmodule Mix.Tasks.Estoque.User do
  @shortdoc "Creates or promotes a user (public sign-up does not exist)"

  @moduledoc """
  Accounts are provisioned deliberately, never by signing up.

      mix estoque.user admin@exemplo.org --role admin
      mix estoque.user almoxarifado@stralog.com.br --role logistics --password "..."

  Roles: `admin`, `operator` (writes to the ledger), `viewer` (reads only).
  An existing account keeps its password and only has its role changed.
  """

  use Mix.Task

  alias EstoqueOS.Accounts
  alias EstoqueOS.Accounts.User

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} =
      OptionParser.parse(args, strict: [role: :string, password: :string])

    case argv do
      [email] ->
        upsert(email, opts)

      _ ->
        Mix.raise(
          "usage: mix estoque.user EMAIL [--role admin|manager|logistics|auditor] [--password P]"
        )
    end
  end

  defp upsert(email, opts) do
    role = opts[:role] || "auditor"

    unless role in User.roles() do
      Mix.raise("unknown role #{role}; expected one of #{Enum.join(User.roles(), ", ")}")
    end

    user =
      case Accounts.get_user_by_email(email) do
        nil ->
          create(email, role, opts)

        user ->
          {:ok, user} = Accounts.update_user_role(user, role)
          user
      end

    report(user)
  end

  # New account: password, confirmation, and role commit together, and the
  # account is force-flagged `must_reset_password: true` — the same rule the
  # web admin screen creates users under. The CLI is just another
  # admin-provisioning entry point; it doesn't get to skip the policy.
  defp create(email, role, opts) do
    create_opts = if opts[:password], do: [password: opts[:password]], else: []

    case Accounts.create_user_with_temporary_password(email, role, create_opts) do
      {:ok, {user, password}} ->
        unless opts[:password] do
          Mix.shell().info("generated password: #{password}")
        end

        user

      {:error, changeset} ->
        Mix.raise("could not create #{email}: #{inspect(changeset.errors)}")
    end
  end

  defp report(user) do
    Mix.shell().info("""
    #{user.email}
      role:      #{user.role}
      confirmed: #{user.confirmed_at || "no"}
    """)
  end
end
