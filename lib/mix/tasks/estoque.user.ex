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
  alias EstoqueOS.Repo

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

    user = Accounts.get_user_by_email(email) || create(email, opts)

    {:ok, user} = Accounts.update_user_role(user, role)

    Mix.shell().info("""
    #{user.email}
      role:      #{user.role}
      confirmed: #{user.confirmed_at || "no"}
    """)
  end

  defp create(email, opts) do
    password = opts[:password] || random_password()

    {:ok, user} = Accounts.register_user(%{email: email})

    user =
      user
      |> User.password_changeset(%{password: password, password_confirmation: password})
      |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
      |> Repo.update!()

    unless opts[:password] do
      Mix.shell().info("generated password: #{password}")
    end

    user
  end

  defp random_password, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64()
end
