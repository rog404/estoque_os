defmodule EstoqueOS.CoercionTest do
  @moduledoc """
  The rules here are small enough to state in the docs and check by running them,
  so the docs are the test. Both functions had drifted across seven copies before
  they were centralised, and both drifts were about the same thing: what an
  unparseable value means. It means unknown. It never means zero.
  """

  use ExUnit.Case, async: true

  doctest EstoqueOS.Coercion, import: true
end
