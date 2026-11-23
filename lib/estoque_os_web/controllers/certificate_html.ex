defmodule EstoqueOSWeb.CertificateHTML do
  @moduledoc """
  The printable certificates. Styling is inline and A4-first: this page exists
  to become paper.
  """

  use EstoqueOSWeb, :html

  embed_templates "certificate_html/*"

  @doc """
  Total for a line, using the symbolic value where no cost is recorded: every
  line on a signed certificate must carry a figure.
  """
  def line_total(entry) do
    cost = entry.unit_cost || symbolic_value()
    Decimal.mult(cost, Decimal.abs(entry.quantity))
  end

  @doc """
  What the certificate declares in total. Not `Inventory.issue_totals/1`, which
  counts only known costs; this must equal the sum of its own lines.
  """
  def declared_total(transaction) do
    Enum.reduce(transaction.entries, Decimal.new(0), fn entry, total ->
      Decimal.add(total, line_total(entry))
    end)
  end

  # Issue entries are negative; the certificate states what was handed over.
  def issued(entry), do: Decimal.abs(entry.quantity)

  @doc """
  Long date for the signature line: 4 de agosto de 2026. Shifts the ledger's
  UTC to São Paulo first so an evening signing does not read as the next day.
  """
  def long_date(%DateTime{} = occurred_at) do
    date = occurred_at |> DateTime.shift_zone!("America/Sao_Paulo") |> DateTime.to_date()

    months =
      ~w(janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro)

    "#{date.day} de #{Enum.at(months, date.month - 1)} de #{date.year}"
  end
end
