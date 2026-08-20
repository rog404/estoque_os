defmodule EstoqueOS.Repo.Migrations.AddReceiptLineCounts do
  use Ecto.Migration

  @moduledoc """
  Every count somebody made of one invoice line, in the order they made them.

  The conference used to take the first number typed and book it, which is how
  the logistics operator could record any quantity at all against an invoice
  that said something else. The box count screen already knew better: a count
  that disagrees is counted again before it is believed.

  `counted_quantity` keeps its meaning — the count of record, still nil while
  nobody has settled on one — and this array is the trail behind it. Two
  entries mean the first count disagreed with the invoice; three mean it
  disagreed twice, and that is no longer a miscount.
  """

  def change do
    alter table(:receipt_lines) do
      add :count_attempts, {:array, :decimal}, null: false, default: []
    end
  end
end
