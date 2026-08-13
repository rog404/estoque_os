defmodule EstoqueOSWeb.DeclaredMoneyTest do
  @moduledoc """
  Two rules that look contradictory and are not: the ledger says "no value
  informed" by keeping NULL, and a document that must carry a figure for every
  line declares the symbolic minimum.

  The dash and the centavo answer different questions, and the point of these
  tests is that the centavo never leaks into the answer the dash belongs to.
  """

  use ExUnit.Case, async: true

  import EstoqueOSWeb.Format

  test "declares the symbolic minimum where a value is required" do
    assert declared_money(nil) == "R$ 0,01"
  end

  test "leaves a known value alone" do
    assert declared_money(Decimal.new("13.50")) == "R$ 13,50"
  end

  test "money/1 still refuses to invent a value" do
    # The reporting surfaces keep saying "unknown", which is what makes stock
    # value and average cost trustworthy.
    assert money(nil) == "—"
    assert unit_price(nil) == "—"
  end

  test "the symbolic value is a Decimal, so a total can agree with the lines" do
    assert Decimal.equal?(symbolic_value(), Decimal.new("0.01"))
  end
end
