defmodule EstoqueOS.Repo.Migrations.AddMarketingRole do
  @moduledoc """
  The person who looks after the marketing stock gets an account of their own.

  The role list is a check constraint rather than an enum type so that adding
  one is this migration and not a table rewrite — but it does mean the database
  has to be told, and the changeset alone is not enough.
  """

  use Ecto.Migration

  def up do
    drop constraint(:users, :users_role_must_be_known)

    create constraint(:users, :users_role_must_be_known,
             check: "role in ('admin', 'manager', 'marketing', 'logistics', 'auditor')"
           )
  end

  def down do
    execute "UPDATE users SET role = 'auditor' WHERE role = 'marketing'"

    drop constraint(:users, :users_role_must_be_known)

    create constraint(:users, :users_role_must_be_known,
             check: "role in ('admin', 'manager', 'logistics', 'auditor')"
           )
  end
end
