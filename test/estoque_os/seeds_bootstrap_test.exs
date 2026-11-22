defmodule EstoqueOS.SeedsBootstrapTest do
  @moduledoc """
  The from-zero bootstrap: locations, the five mission kits (only the patient
  kit carries items), and the four role accounts — no catalog, no stock. It is
  what a fresh test deployment loads on first boot.
  """

  use EstoqueOS.DataCase, async: true

  alias EstoqueOS.{Accounts, Kits, Seeds}

  describe "bootstrap/0" do
    test "creates the four role accounts, ready to log in" do
      Seeds.bootstrap()

      for {email, role} <- [
            {"admin@estoque.local", "admin"},
            {"estoque@estoque.local", "manager"},
            {"logistica@estoque.local", "logistics"},
            {"marketing@estoque.local", "marketing"}
          ] do
        user = Accounts.get_user_by_email(email)
        assert user.role == role
        # Loggable straight away: the forced first-login reset is cleared.
        refute user.must_reset_password
        assert Accounts.get_user_by_email_and_password(email, Seeds.bootstrap_password())
      end
    end

    test "creates the five kits, only the patient kit with items" do
      Seeds.bootstrap()

      kits = Kits.list_kits()
      names = kits |> Enum.map(& &1.name) |> Enum.sort()

      assert names ==
               [
                 "Kit Anestesia",
                 "Kit Enfermagem",
                 "Kit Paciente",
                 "Kit Pré e Pós",
                 "Kit Recuperação"
               ]

      patient =
        kits |> Enum.find(&(&1.name == "Kit Paciente")) |> Map.fetch!(:id) |> Kits.get_kit!()

      assert length(patient.items) > 20
      # The hand-written list has no catalog yet, so every line is unresolved.
      assert Enum.all?(patient.items, &is_nil(&1.product_id))

      for other <- ~w(Anestesia Enfermagem) do
        kit =
          kits |> Enum.find(&(&1.name == "Kit #{other}")) |> Map.fetch!(:id) |> Kits.get_kit!()

        assert kit.items == []
      end
    end

    test "is safe to run twice" do
      Seeds.bootstrap()
      Seeds.bootstrap()

      assert Accounts.get_user_by_email("admin@estoque.local")
      assert length(Kits.list_kits()) == 5
    end
  end
end
