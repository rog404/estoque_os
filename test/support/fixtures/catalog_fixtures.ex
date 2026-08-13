defmodule EstoqueOS.CatalogFixtures do
  @moduledoc """
  Fixtures for the `EstoqueOS.Catalog` context.
  """

  alias EstoqueOS.Catalog.{Product, ProductGroup, ProductIdentifier, Supplier, UnitConversion}
  alias EstoqueOS.Repo

  def unique_cnpj, do: String.pad_leading("#{System.unique_integer([:positive])}", 14, "0")

  def unique_gtin, do: String.pad_leading("#{System.unique_integer([:positive])}", 13, "7")

  def supplier_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{cnpj: unique_cnpj(), legal_name: "Fornecedor #{System.unique_integer()}"})
    |> then(&Supplier.changeset(%Supplier{}, &1))
    |> Repo.insert!()
  end

  def product_group_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{name: "Grupo #{System.unique_integer([:positive])}"})
    |> then(&ProductGroup.changeset(%ProductGroup{}, &1))
    |> Repo.insert!()
  end

  def product_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{name: "Produto #{System.unique_integer([:positive])}", stock_unit: "UN"})
    |> then(&Product.changeset(%Product{}, &1))
    |> Repo.insert!()
  end

  def product_identifier_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{kind: "gtin", value: unique_gtin()})
    |> then(&ProductIdentifier.changeset(%ProductIdentifier{}, &1))
    |> Repo.insert!()
  end

  def unit_conversion_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{from_unit: "CX", factor: Decimal.new(100)})
    |> then(&UnitConversion.changeset(%UnitConversion{}, &1))
    |> Repo.insert!()
  end
end
