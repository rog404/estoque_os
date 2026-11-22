defmodule EstoqueOSWeb.FormatTest do
  @moduledoc """
  The doc examples are the check, so the rounding distinction between `money/1`
  and `unit_price/1` cannot quietly collapse.
  """

  use ExUnit.Case, async: true

  doctest EstoqueOSWeb.Format, import: true
end
