defmodule EstoqueOS.Catalog.SchemasTest do
  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Catalog.{Product, ProductGroup, ProductIdentifier, Supplier, UnitConversion}

  describe "supplier" do
    test "strips CNPJ punctuation" do
      supplier = supplier_fixture(%{cnpj: "55.666.777/0001-81"})

      assert supplier.cnpj == "55666777000181"
    end

    test "rejects a CNPJ that is not 14 digits" do
      changeset = Supplier.changeset(%Supplier{}, %{cnpj: "123", legal_name: "X"})

      refute changeset.valid?
      assert "has invalid format" in errors_on(changeset).cnpj
    end

    test "the same CNPJ cannot be registered twice" do
      cnpj = unique_cnpj()
      supplier_fixture(%{cnpj: cnpj})

      assert {:error, changeset} =
               %Supplier{}
               |> Supplier.changeset(%{cnpj: cnpj, legal_name: "Outro"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).cnpj
    end
  end

  describe "product" do
    test "normalizes name and unit and keeps only NCM digits" do
      product = product_fixture(%{name: "  Gaze  ", stock_unit: "un", ncm: "3005.90.99"})

      assert product.name == "Gaze"
      assert product.stock_unit == "UN"
      assert product.ncm == "30059099"
    end

    test "names collide regardless of case" do
      product_fixture(%{name: "Compressa de gaze"})

      assert {:error, changeset} =
               %Product{}
               |> Product.changeset(%{name: "COMPRESSA DE GAZE"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).name
    end

    test "rejects an NCM that is not 8 digits" do
      changeset = Product.changeset(%Product{}, %{name: "X", ncm: "123"})

      refute changeset.valid?
      assert "has invalid format" in errors_on(changeset).ncm
    end

    test "belongs to a group" do
      group = product_group_fixture(%{name: "Agulhas"})
      product = product_fixture(%{product_group_id: group.id})

      assert Repo.preload(group, :products).products |> Enum.map(& &1.id) == [product.id]
    end
  end

  describe "product group" do
    test "names collide regardless of case" do
      product_group_fixture(%{name: "Agulhas"})

      assert {:error, changeset} =
               %ProductGroup{}
               |> ProductGroup.changeset(%{name: "agulhas"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "product identifier" do
    test "a GTIN can only point at one product" do
      gtin = unique_gtin()
      product_identifier_fixture(%{product_id: product_fixture().id, value: gtin})

      assert {:error, changeset} =
               %ProductIdentifier{}
               |> ProductIdentifier.changeset(%{
                 kind: "gtin",
                 value: gtin,
                 product_id: product_fixture().id
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).kind
    end

    test "the same supplier code may repeat across suppliers" do
      code = "9120"
      product = product_fixture()

      for _ <- 1..2 do
        assert %ProductIdentifier{} =
                 product_identifier_fixture(%{
                   kind: "supplier_code",
                   value: code,
                   product_id: product.id,
                   supplier_id: supplier_fixture().id
                 })
      end
    end

    test "a supplier code without a supplier is rejected" do
      changeset =
        ProductIdentifier.changeset(%ProductIdentifier{}, %{
          kind: "supplier_code",
          value: "9120",
          product_id: product_fixture().id
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).supplier_id
    end

    test "rejects a value that is not a plausible GTIN" do
      changeset =
        ProductIdentifier.changeset(%ProductIdentifier{}, %{
          kind: "gtin",
          value: "SEM GTIN",
          product_id: product_fixture().id
        })

      refute changeset.valid?
      assert "has invalid format" in errors_on(changeset).value
    end
  end

  describe "unit conversion" do
    test "one factor per product and commercial unit" do
      product = product_fixture()
      unit_conversion_fixture(%{product_id: product.id, from_unit: "CX"})

      assert {:error, changeset} =
               %UnitConversion{}
               |> UnitConversion.changeset(%{
                 product_id: product.id,
                 from_unit: "cx",
                 factor: Decimal.new(50)
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).product_id
    end

    test "rejects a factor of zero or less" do
      changeset =
        UnitConversion.changeset(%UnitConversion{}, %{
          product_id: product_fixture().id,
          from_unit: "CX",
          factor: Decimal.new(0)
        })

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).factor
    end
  end
end
