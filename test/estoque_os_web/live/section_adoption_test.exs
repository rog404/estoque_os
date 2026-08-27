defmodule EstoqueOSWeb.SectionAdoptionTest do
  @moduledoc """
  Every screen says where it is.

  Three screens had no answer: a product opened from a stock row, a receipt
  opened from the conference list, and the declaration that travels with a
  load. None has a menu entry above it — there is no `/products` — so the
  longest-prefix match found nothing and they rendered with no rail colour and
  no section name. They are the three deepest screens in the app, reached from
  a row and nothing else, and on a phone the menu is behind a hamburger: they
  were the screens that most needed the answer and the only ones without it.
  """

  use EstoqueOSWeb.ConnCase, async: true

  alias EstoqueOSWeb.Layouts

  test "a product belongs to stock" do
    assert Layouts.active_section("/products/42") == "stock"
    assert Layouts.section_label("/products/42") == "Estoque"
  end

  test "a receipt belongs to the conference it was opened from" do
    assert Layouts.active_section("/receipts/7") == "operation"
  end

  test "a shipment's declaration belongs where transit lives" do
    assert Layouts.active_section("/shipments/3/declaracao") == "reports"
  end

  # The adoption is a prefix match like every other, so it must not claim a
  # neighbour that merely starts with the same letters.
  test "adoption does not swallow a path that only looks similar" do
    assert Layouts.active_section("/products-archive") == nil
  end

  # And it never overrides a real menu entry.
  test "a path the menu owns keeps its own section" do
    assert Layouts.active_section("/stock") == "stock"
    assert Layouts.active_section("/boxes/1/count") == "stock"
  end
end
