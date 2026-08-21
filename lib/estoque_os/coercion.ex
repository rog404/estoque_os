defmodule EstoqueOS.Coercion do
  @moduledoc """
  Turning what a form sends into what the domain expects.

  These two functions were copy-pasted into seven modules and drifted: one copy
  did not handle the empty string a "no box" select sends, which crashed a
  LiveView in production shape; another swallowed a bad quantity into `0`,
  which reads as "nothing to pick" instead of as an error. One behavior now.
  """

  @doc """
  A value from attrs that may have arrived keyed by atom or by string.

  A context is called from two directions: a LiveView hands it a form's string
  keys, and code hands it atoms. Asking twice at every call site — reaching for
  the atom key and falling back to the string one — answered the same question
  inline thirty-six times, and every fallback was one more branch for a reader
  to check.

      iex> field(%{user_id: 7}, :user_id)
      7

      iex> field(%{"user_id" => 7}, :user_id)
      7

      iex> field(%{}, :user_id)
      nil

  An atom key that is present wins even when its value is falsy, which the `||`
  form got wrong: a checkbox that came back `false` means false, not "look for a
  string key and then give up".

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

  This existed as a private copy in eight modules, in three different
  behaviours: one did not handle `nil`, one did not trim, one trimmed. So `" "`
  was a blank on five screens and a value on a sixth, which is not a decision
  anybody made — it is what happens when the same four lines get rewritten
  eight times.

  A form always sends every field it renders, so `""` is what an untouched
  input looks like and `" "` is what a nervous thumb looks like. Both are
  nothing.
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

  Three report screens each had their own copy: a date input posts "" while
  somebody is retyping it, and a period that collapsed to nil mid-keystroke
  emptied the report under them. The fallback is what makes the field usable, so
  it is part of the function rather than something each caller remembers.

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

  A "no box" select posts an empty string, and the answer to that is "no box",
  never box zero.

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

  Returns nil on junk — never zero. A quantity nobody could parse is unknown,
  and treating it as zero is how a count silently empties a position.

      iex> to_decimal("12")
      Decimal.new("12")

  A Brazilian keyboard types a comma, and the warehouse types what it types:

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
