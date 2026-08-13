defmodule EstoqueOSWeb.CertificateHTML do
  @moduledoc """
  The printable certificates. Styling is inline and A4-first: this page exists
  to become paper.
  """

  use EstoqueOSWeb, :html

  embed_templates "certificate_html/*"

  @doc """
  Total for a line, declaring the symbolic minimum where no value was informed.

  A certificate is signed by someone accepting goods, so every line it lists has
  to carry a figure. Donated items have no market value on record — a used toy
  cannot be priced — and the document says so in a note rather than leaving a
  blank the reader has to interpret.
  """
  def line_total(entry) do
    cost = entry.unit_cost || symbolic_value()
    Decimal.mult(cost, Decimal.abs(entry.quantity))
  end

  @doc """
  What the certificate declares in total.

  Deliberately not `Inventory.issue_totals/1`, which reports only what is
  *known* — that is the right answer for stock value and the wrong one for a
  document that must add up to the sum of its own lines.
  """
  def declared_total(transaction) do
    Enum.reduce(transaction.entries, Decimal.new(0), fn entry, total ->
      Decimal.add(total, line_total(entry))
    end)
  end

  @doc """
  How much left, as a positive number.

  Ledger entries for an issue are negative — that is what makes it an issue —
  but a certificate states what was handed over, not a signed delta.
  """
  def issued(entry), do: Decimal.abs(entry.quantity)

  @doc """
  Long date for the signature line: 4 de agosto de 2026.

  Takes the transaction's own `DateTime` — UTC on the ledger — and shifts it
  to São Paulo first, the same as every other date on screen. Signing "at
  night" should not read as the next day just because the ledger keeps UTC.
  """
  def long_date(%DateTime{} = occurred_at) do
    date = occurred_at |> DateTime.shift_zone!("America/Sao_Paulo") |> DateTime.to_date()

    months =
      ~w(janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro)

    "#{date.day} de #{Enum.at(months, date.month - 1)} de #{date.year}"
  end
end
