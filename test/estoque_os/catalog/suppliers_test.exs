defmodule EstoqueOS.Catalog.SuppliersTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Catalog

  describe "upsert_supplier/1" do
    # An NF-e issued under a CPF (a donation's nota avulsa) arrives with no CNPJ.
    test "an issuer without a CNPJ is an answer, not a crash" do
      assert {:error, :supplier_missing_cnpj} =
               Catalog.upsert_supplier(%{cnpj: nil, legal_name: "Doador Pessoa Física"})

      assert {:error, :supplier_missing_cnpj} =
               Catalog.upsert_supplier(%{cnpj: "", legal_name: "Doador Pessoa Física"})
    end

    test "finds the existing supplier however the CNPJ is punctuated" do
      supplier = supplier_fixture(%{cnpj: "55666777000181"})

      assert {:ok, found} =
               Catalog.upsert_supplier(%{cnpj: "55.666.777/0001-81", legal_name: "Outro Nome"})

      assert found.id == supplier.id
    end
  end
end
