defmodule EstoqueOSWeb.Format do
  @moduledoc """
  How numbers and dates are written on screen, in one place.

  Unit prices get four decimals via their own function: rounding R$ 0,2695 to
  R$ 0,27 destroys the number that justifies the product.
  """

  @doc """
  A quantity, without trailing zeros. Nil is not zero — it is unknown.

      iex> quantity(Decimal.new("12.0000"))
      "12"

      iex> quantity(Decimal.new("2.5000"))
      "2,5"

      iex> quantity(nil)
      "—"

  A fraction uses the Brazilian comma.

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

  Not `money/1`: two decimals would round R$ 0,2695 to R$ 0,27.

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
  Money for a surface that must carry a figure on every line (transport
  manifest, signed certificate): declares the symbolic minimum instead of a dash.

  Presentation only. The ledger keeps `unit_cost` NULL; R$ 0,01 in
  `transaction_entries` would poison average cost and stock value.

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

  A bare `Date` is not converted. A `DateTime` is the ledger's UTC and is
  shifted to São Paulo first, so a night-time count does not read as tomorrow.
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
