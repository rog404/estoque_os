defmodule EstoqueOS.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users) do
      add :email, :citext, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      # admin  everything, plus who else gets an account
      # manager    the coordinator: the whole operation, money included
      # logistics  the operator who handles boxes: counts, load-outs, returns.
      #            No prices, anywhere.
      # auditor    reads everything, money and ledger included. Writes nothing.
      # A new account can look; writing is granted deliberately.
      add :role, :string, null: false, default: "auditor"
      # An account an administrator created carries a password the administrator
      # chose, which means two people know it. Set here, cleared the first time
      # the person picks their own — until then every write is refused, so a
      # shared password cannot become a signature in the ledger.
      add :must_reset_password, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    create constraint(:users, :users_role_must_be_known,
             check: "role in ('admin', 'manager', 'logistics', 'auditor')"
           )

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
