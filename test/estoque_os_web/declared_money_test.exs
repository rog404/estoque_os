defmodule EstoqueOSWeb.DeclaredMoneyTest do
  @moduledoc """
  The ledger keeps NULL for "no value informed"; a document that needs a figure
  per line declares the symbolic minimum. The centavo must never leak into the
  reporting surfaces, which show a dash for unknown.
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
    assert money(nil) == "—"
    assert unit_price(nil) == "—"
  end

  test "the symbolic value is a Decimal, so a total can agree with the lines" do
    assert Decimal.equal?(symbolic_value(), Decimal.new("0.01"))
  end
end
