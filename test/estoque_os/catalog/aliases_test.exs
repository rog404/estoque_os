defmodule EstoqueOS.Catalog.AliasesTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Catalog

  setup do
    %{product: product_fixture(%{name: "Equipo macrogotas"})}
  end

  describe "add_alias/2" do
    test "records an alternative name", %{product: product} do
      assert {:ok, product_alias} = Catalog.add_alias(product, "equipo")
      assert product_alias.name == "equipo"
      assert product_alias.normalized == "equipo"
      assert [listed] = Catalog.list_aliases(product)
      assert listed.id == product_alias.id
    end

    test "normalizes case and accents so two spellings collide", %{product: product} do
      assert {:ok, _} = Catalog.add_alias(product, "Equípo")
      assert {:error, :taken} = Catalog.add_alias(product, "equipo")
    end

    test "refuses a blank name", %{product: product} do
      assert {:error, :blank} = Catalog.add_alias(product, "   ")
    end

    test "refuses a name another product already uses", %{product: product} do
      other = product_fixture(%{name: "Soro fisiológico"})
      {:ok, _} = Catalog.add_alias(other, "jelco")

      assert {:error, :taken} = Catalog.add_alias(product, "JELCO")
    end
  end

  describe "search_products/2" do
    test "finds a product by an alias unlike its name, flagged :alias", %{product: product} do
      {:ok, _} = Catalog.add_alias(product, "soroflex")

      assert [%{product: found, matched: :alias}] = Catalog.search_products("soroflex")
      assert found.id == product.id
    end
  end

  describe "delete_alias/1" do
    test "drops the name", %{product: product} do
      {:ok, product_alias} = Catalog.add_alias(product, "equipo")

      assert {:ok, _} = Catalog.delete_alias(product_alias.id)
      assert Catalog.list_aliases(product) == []
    end
  end
end
