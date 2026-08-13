defmodule EstoqueOSWeb.Format do
  @moduledoc """
  How numbers and dates are written on screen, in one place.

  These formatters were copy-pasted into fifteen LiveViews and drifted: money
  rounded to two decimals on most screens and four on the invoice, so the same
  lot read R$ 1,2345 on one screen and R$ 1,23 on the next — in a system whose
  credibility rests on money being exact.

  The four-decimal case was not a mistake, it was a different job: a unit price
  of R$ 0,2695 rounded to R$ 0,27 destroys the number that justifies the
  product. So it gets its own function and is chosen deliberately.
  """

  @doc """
  A quantity, without trailing zeros. Nil is not zero — it is unknown.

      iex> quantity(Decimal.new("12.0000"))
      "12"

      iex> quantity(Decimal.new("2.5000"))
      "2,5"

      iex> quantity(nil)
      "—"

  A fraction is written the way it is written in Brazil. `money/1` had always
  done this and `quantity/1` had not, so half a litre read "0.5" on a screen
  whose every other number read "0,5".

      iex> quantity(Decimal.new("2.50"))
      "2,5"

  """
  def quantity(nil), do: "—"
  def quantity(value) when is_integer(value), do: Integer.to_string(value)

  def quantity(%Decimal{} = value) do
    value
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
    |> String.replace(".", ",")
  end

  @doc """
  Money, two decimals, Brazilian notation. Nil means no value informed.

      iex> money(Decimal.new("1234.5"))
      "R$ 1234,50"

      iex> money(nil)
      "—"

  """
  def money(nil), do: "—"
  def money(%Decimal{} = value), do: brl(Decimal.round(value, 2))

  @doc """
  A unit price, four decimals.

  Deliberately not `money/1`: a pack of 50 electrodes at R$ 13,475 is R$ 0,2695
  each, and two decimals would round that to R$ 0,27.

      iex> unit_price(Decimal.new("0.2695"))
      "R$ 0,2695"

      iex> money(Decimal.new("0.2695"))
      "R$ 0,27"

  """
  def unit_price(nil), do: "—"

  def unit_price(%Decimal{} = value) do
    value |> Decimal.round(4) |> Decimal.normalize() |> brl()
  end

  @doc """
  Money for a surface that is not allowed to say "no value".

  A donated toy cannot be priced — nobody knows what a used toy is worth — but a
  transport manifest or a signed certificate has to carry a figure for every line
  it lists. So those surfaces declare the symbolic minimum instead of a dash.

  This is presentation, and only presentation. The ledger keeps `unit_cost` NULL,
  which is the honest statement that no value was ever informed; writing R$ 0,01
  into `transaction_entries` would poison average cost and stock value for good.
  If this number ever reaches a changeset, something is wrong.

      iex> declared_money(nil)
      "R$ 0,01"

      iex> declared_money(Decimal.new("3.5"))
      "R$ 3,50"

  """
  @symbolic_value Decimal.new("0.01")

  def declared_money(nil), do: money(@symbolic_value)
  def declared_money(%Decimal{} = value), do: money(value)

  @doc "The figure `declared_money/1` falls back to, for a total to agree with it."
  def symbolic_value, do: @symbolic_value

  @doc """
  A date the way it is written in Brazil.

      iex> date(~D[2027-07-31])
      "31/07/2027"

      iex> date(nil)
      "—"

  A bare `Date` has no timezone to convert — it is already whatever day it
  is meant to be. A `DateTime` is the ledger's UTC, and 23:30 in São Paulo is
  already past midnight there; converting first is what keeps a count made
  at night from reading as tomorrow.
  """
  def date(nil), do: "—"
  def date(%Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")
  def date(%DateTime{} = datetime), do: datetime |> local() |> DateTime.to_date() |> date()

  @doc "A date and time, for a log an auditor reads — in São Paulo time, not the ledger's UTC."
  def datetime(nil), do: "—"
  def datetime(%DateTime{} = value), do: value |> local() |> Calendar.strftime("%d/%m/%Y %H:%M")

  @brazil "America/Sao_Paulo"

  defp local(%DateTime{} = value), do: DateTime.shift_zone!(value, @brazil)

  defp brl(%Decimal{} = value) do
    "R$ " <> (value |> Decimal.to_string(:normal) |> String.replace(".", ","))
  end
end
