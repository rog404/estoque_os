defmodule EstoqueOS.Repo.Migrations.AddInvoiceSegment do
  use Ecto.Migration

  # Which stock a delivery is for, decided when it is imported rather than
  # inferred from where its lines eventually landed.
  #
  # Inferring was the old rule and it broke the marketing role's first minute:
  # a freshly imported invoice has no product on any line yet, so "does this
  # invoice have a marketing item" answered no and the screen refused the
  # person who had just uploaded the file.
  def up do
    alter table(:invoices) do
      add :segment, :string, null: false, default: "medical"
    end

    create constraint(:invoices, :invoices_segment_must_be_known,
             check: "segment in ('medical', 'marketing')"
           )

    # Invoices already on record keep the stock their lines are actually in.
    # Only the ones whose every resolved line is marketing move — a mixed
    # delivery stays surgical, which is the side that holds the controlled
    # goods and the stricter reading.
    execute """
    UPDATE invoices SET segment = 'marketing'
    WHERE EXISTS (
      SELECT 1 FROM invoice_items i
      JOIN products p ON p.id = i.product_id
      WHERE i.invoice_id = invoices.id AND p.segment = 'marketing'
    )
    AND NOT EXISTS (
      SELECT 1 FROM invoice_items i
      JOIN products p ON p.id = i.product_id
      WHERE i.invoice_id = invoices.id AND p.segment <> 'marketing'
    )
    """
  end

  def down do
    drop constraint(:invoices, :invoices_segment_must_be_known)

    alter table(:invoices) do
      remove :segment
    end
  end
end
