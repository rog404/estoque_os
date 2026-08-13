defmodule EstoqueOS.Accounts.UserRoleTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.AccountsFixtures

  alias EstoqueOS.Accounts.User

  describe "role" do
    test "a new account can look, not write" do
      # Writing to the ledger is granted deliberately, never by signing up.
      assert user_fixture().role == "auditor"
    end

    test "role_changeset/2 accepts every known role" do
      user = user_fixture()

      for role <- User.roles() do
        assert {:ok, updated} = user |> User.role_changeset(%{role: role}) |> Repo.update()
        assert updated.role == role
      end
    end

    test "role_changeset/2 rejects unknown roles" do
      changeset = User.role_changeset(user_fixture(), %{role: "root"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).role
    end

    test "the database rejects unknown roles as well" do
      user = user_fixture()

      assert_raise Ecto.ConstraintError, ~r/users_role_must_be_known/, fn ->
        user
        |> Ecto.Changeset.change(role: "root")
        |> Repo.update()
      end
    end
  end
end
