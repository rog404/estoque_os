defmodule EstoqueOSWeb.FormatTest do
  @moduledoc """
  These formatters drifted across fifteen LiveViews before they were centralised,
  and the drift that mattered was rounding: the same lot read R$ 1,2345 on one
  screen and R$ 1,23 on the next. The examples in the docs are the check, so the
  distinction between `money/1` and `unit_price/1` cannot quietly collapse again.
  """

  use ExUnit.Case, async: true

  doctest EstoqueOSWeb.Format, import: true
end
