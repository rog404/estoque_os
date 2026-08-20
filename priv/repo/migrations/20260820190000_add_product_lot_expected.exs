defmodule EstoqueOS.Repo.Migrations.AddProductLotExpected do
  @moduledoc """
  Whether a lot number is missing or simply does not exist.

  The same distinction `expiry_expected` already draws for dates. A gauze pack
  arrives with a lot printed on it and no number means somebody did not read
  it; a donated blanket has no lot because blankets do not have lots. Flagging
  the second one buries the first.
  """

  use Ecto.Migration

  def change do
    alter table(:products) do
      add :lot_expected, :boolean, null: false, default: true
    end
  end
end
