defmodule EstoqueOS.Coercion do
  @moduledoc """
  Turning what a form sends into what the domain expects, in one place.
  """

  @doc """
  A value from attrs that may be keyed by atom (code) or by string (LiveView form).

      iex> field(%{user_id: 7}, :user_id)
      7

      iex> field(%{"user_id" => 7}, :user_id)
      7

      iex> field(%{}, :user_id)
      nil

  An atom key that is present wins even when falsy (a `false` checkbox is false).

      iex> field(%{"consume_missing" => true, consume_missing: false}, :consume_missing)
      false

  """
  def field(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  def field(attrs, key) when is_list(attrs) and is_atom(key), do: Keyword.get(attrs, key)

  @doc """
  Nothing typed, as `nil` — including a field holding only spaces.

  A form sends every field it renders, so `""` is an untouched input and `" "`
  a stray keystroke; both are nothing.
  """
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(value), do: value

  @doc """
  A date from a form value, keeping what was already there when the field is
  blank or malformed.

  A date input posts "" while being retyped; the fallback keeps the report from
  emptying mid-keystroke.

      iex> parse_date("2026-08-21", ~D[2026-01-01])
      ~D[2026-08-21]

      iex> parse_date("", ~D[2026-01-01])
      ~D[2026-01-01]

      iex> parse_date("not a date", ~D[2026-01-01])
      ~D[2026-01-01]
  """
  def parse_date(nil, fallback), do: fallback
  def parse_date("", fallback), do: fallback

  def parse_date(value, fallback) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> fallback
    end
  end

  def parse_date(%Date{} = date, _fallback), do: date
  def parse_date(_value, fallback), do: fallback

  @doc """
  An id from a form value. Blank means "none", not zero.

      iex> to_id("42")
      42

      iex> to_id(42)
      42

  A "no box" select posts an empty string: that is "no box", never box zero.

      iex> to_id("")
      nil

      iex> to_id(nil)
      nil

  Junk is unknown rather than a number:

      iex> to_id("abc")
      nil

  """
  def to_id(nil), do: nil
  def to_id(""), do: nil
  def to_id(id) when is_integer(id), do: id

  def to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  @doc """
  A decimal from a typed value, accepting the comma a Brazilian keyboard types.

  Returns nil on junk, never zero: parsing junk as zero silently empties a
  position in a count.

      iex> to_decimal("12")
      Decimal.new("12")


      iex> to_decimal("1,5")
      Decimal.new("1.5")

      iex> to_decimal(" 2,25 ")
      Decimal.new("2.25")

  Unparseable is unknown, and unknown is not zero:

      iex> to_decimal("abc")
      nil

      iex> to_decimal("")
      nil

  """
  def to_decimal(nil), do: nil
  def to_decimal(%Decimal{} = value), do: value
  def to_decimal(value) when is_integer(value), do: Decimal.new(value)
  def to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  def to_decimal(value) when is_binary(value) do
    case value |> String.trim() |> String.replace(",", ".") |> Decimal.parse() do
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end
end
