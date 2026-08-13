defmodule EstoqueOS.CatalogSearchTest do
  @moduledoc """
  Supplier naming chaos is what killed the previous system, so search follows
  the same order the importer does: a code is an answer, a name is a guess.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Catalog

  setup do
    supplier = supplier_fixture()
    needle = product_fixture(%{name: "Agulha hipodérmica 40x12"})
    other = product_fixture(%{name: "Sterecam agulha estéril"})

    product_identifier_fixture(%{kind: "gtin", value: "7899780182401", product_id: needle.id})

    product_identifier_fixture(%{
      kind: "supplier_code",
      value: "91538",
      product_id: other.id,
      supplier_id: supplier.id
    })

    %{supplier: supplier, needle: needle, other: other}
  end

  test "a scanned GTIN lands on one product and stops", %{needle: needle} do
    assert [%{product: found, matched: :gtin}] = Catalog.search_products("7899780182401")
    assert found.id == needle.id
  end

  test "find_by_code/2 is what a scanner's Enter resolves to", %{needle: needle} do
    assert Catalog.find_by_code("7899780182401").id == needle.id
    assert Catalog.find_by_code("nao-existe") == nil
  end

  test "a supplier code only answers for that supplier", %{supplier: supplier, other: other} do
    assert [%{product: found, matched: :supplier_code}] =
             Catalog.search_products("91538", supplier_id: supplier.id)

    assert found.id == other.id

    # Without the supplier, a bare "91538" is not that supplier's code.
    assert Catalog.search_products("91538") == []
  end

  test "falls back to the group's synonyms before giving up" do
    {:ok, group} = Catalog.create_product_group(%{name: "Agulhas"})
    {:ok, _} = Catalog.add_group_synonym(%{product_group_id: group.id, name: "Sterecam"})
    product = product_fixture(%{name: "Agulha 30G", product_group_id: group.id})

    # "Sterecam" is also literally the name of another product here, so both
    # match — the synonym leads, because a curated alias beats a substring.
    assert [%{product: found, matched: :synonym} | rest] = Catalog.search_products("sterecam")
    assert found.id == product.id
    assert Enum.all?(rest, &(&1.matched == :name))
  end

  test "matching by name is the weakest evidence and says so", %{needle: needle} do
    assert [%{product: found, matched: :name} | _] = Catalog.search_products("hipodérmica")
    assert found.id == needle.id
  end

  test "an empty term matches nothing rather than everything" do
    assert Catalog.search_products("") == []
    assert Catalog.search_products("   ") == []
  end
end
