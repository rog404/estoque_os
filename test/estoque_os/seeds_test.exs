defmodule EstoqueOS.SeedsTest do
  @moduledoc """
  Runs the seeds against the real spreadsheets, so the messy rows in them stay
  covered: 326 catalog lines with four repeated descriptions, forty without an
  NCM, three whose NCM is not an NCM, and five with no quantity.

  Serial, for the same reason `SeedsLocationsTest` is — and this is the half
  that was missed. Seeding the catalog inserts 322 real product names in one
  transaction, and `products` carries a unique index on `lower(name)`. Two dozen
  other suites build fixtures using those same real names, because that is what
  the warehouse calls things.

  A unique index conflicts between concurrent transactions even under the
  sandbox, where neither can see the other's rows: the second insert of a name
  waits on the first transaction, which under the sandbox does not commit until
  its test ends. One shared name is a stall; two, taken in opposite orders, is a
  deadlock — and this suite holds 322 of them at once, so it was one half of
  every deadlock the suite produced.
  """

  use EstoqueOS.DataCase, async: false

  doctest EstoqueOS.Seeds, import: true

  import Ecto.Query

  alias EstoqueOS.Catalog.Product
  alias EstoqueOS.Kits.{Kit, KitItem}
  alias EstoqueOS.Seeds

  @samples EstoqueOS.Samples.dir()

  describe "catalog" do
    setup do
      %{products: Seeds.seed_catalog(catalog_path())}
    end

    test "loads the standard supply table, minus the repeated lines", %{products: products} do
      # 326 rows, 4 of which repeat a description.
      assert length(products) == 322
      assert Repo.aggregate(Product, :count) == 322
    end

    test "un-pastes the spreadsheet range somebody dropped into a description" do
      # Row 11 of the real file reads "SOLUÇÃ+A1:P376O INJETÁVEL". A product
      # nobody can spell is a product nobody can search for, and this catalog
      # exists because searching the last one was impossible.
      assert Repo.exists?(
               from p in Product,
                 where: p.name == "AGUA DESTILADA PARA INJEÇÃO - AMPOLA 10ML - SOLUÇÃO INJETÁVEL"
             )

      refute Repo.exists?(from p in Product, where: like(p.name, "%A1:P376%"))
    end

    test "leaves a concentration alone, colon and all" do
      # 1:200,000 is how an anaesthetic with adrenaline is written. The artefact
      # stripper wants letters on both sides of the colon precisely so this
      # survives.
      assert Repo.exists?(from p in Product, where: like(p.name, "%1:200,000%"))
    end

    test "keeps stock in individual units regardless of the purchase packaging" do
      assert Repo.aggregate(from(p in Product, where: p.stock_unit != "UN"), :count) == 0

      pacote =
        Repo.one!(from p in Product, where: p.name == "ABAIXADOR DE LINGUA MADEIRA PCT C/100")

      assert pacote.notes =~ "Unidade de compra na tabela padrão: PACOTE"
    end

    test "the mission quantity becomes the minimum stock" do
      product = Repo.one!(from p in Product, where: p.name == "ÁCIDO TRANEXÂMICO 5ML")

      assert Decimal.equal?(product.min_stock_override, Decimal.new(60))
      assert product.ncm == "90189010"
      assert product.sector == "ANESTESIA - MEDICAMENTOS"
    end

    test "medications are flagged as controlled for a human to refine" do
      product = Repo.one!(from p in Product, where: p.name == "ÁCIDO TRANEXÂMICO 5ML")
      assert product.controlled

      gauze = Repo.one!(from p in Product, where: p.name == "ABAIXADOR DE LINGUA INFANTL")
      refute gauze.controlled
    end

    test "an NCM that is not an NCM is kept as a note instead of being stored" do
      product =
        Repo.one!(
          from p in Product, where: p.name == "CONJUNTO REANIMADOR DESCARTAVEL PEDIATRICO 500ML"
        )

      assert product.ncm == nil
      assert product.notes =~ "NCM na tabela padrão: 20111223001 (inválido)"

      # This one the spreadsheet turned into a date.
      guedel = Repo.one!(from p in Product, where: p.name == "CANULA DE GUEDEL 90MM NR. 3")
      assert guedel.ncm == nil
      assert guedel.notes =~ "(inválido)"
    end

    test "rows without an NCM or a quantity still load" do
      # No NCM, but a quantity.
      alcool = Repo.one!(from p in Product, where: p.name == "ALCOOL 70%")
      assert alcool.ncm == nil
      assert Decimal.equal?(alcool.min_stock_override, Decimal.new(10))

      # Neither NCM nor quantity.
      canula = Repo.one!(from p in Product, where: p.name == "CÂNULA NASOFARÍNGEA 28FR")
      assert canula.ncm == nil
      assert canula.min_stock_override == nil

      # A quantity of zero is not a minimum stock of zero — it is unknown.
      swab =
        Repo.one!(
          from p in Product,
            where: p.name == "SWAB HASTE PLÁSTICA - ESTÉRIL - ENVELOPE C/ 01 UNID"
        )

      assert swab.min_stock_override == nil
    end

    test "running twice does not duplicate products" do
      Seeds.seed_catalog(catalog_path())

      assert Repo.aggregate(Product, :count) == 322
    end
  end

  describe "kits" do
    setup do
      Seeds.seed_catalog(catalog_path())
      %{kits: Seeds.seed_kits(Path.join(@samples, "Kits.xlsx"))}
    end

    test "loads one kit per sheet, named as the sheet titles them", %{kits: kits} do
      names = kits |> Enum.map(& &1.name) |> Enum.sort()

      assert length(kits) == 5
      assert "Kit Paciente" in names
      assert "Kit Anestesia" in names
      assert "Kit enfermagem" in names
    end

    test "loads every component with its quantity" do
      kit = Repo.one!(from k in Kit, where: k.name == "Kit Paciente")
      items = Repo.all(from i in KitItem, where: i.kit_id == ^kit.id)

      assert length(items) == 28

      avental = Enum.find(items, &(&1.description == "Avental EG"))
      assert Decimal.equal?(avental.quantity, Decimal.new(4))
    end

    test "components keep their wording when the catalog has no exact match" do
      kit = Repo.one!(from k in Kit, where: k.name == "Kit Anestesia")
      items = Repo.all(from i in KitItem, where: i.kit_id == ^kit.id)

      # The kit sheets name things loosely, so most lines stay unresolved and
      # visible rather than being matched to the wrong product.
      assert Enum.any?(items, &is_nil(&1.product_id))
      assert Enum.all?(items, &(&1.description != nil))
    end

    test "running twice does not duplicate kits" do
      Seeds.seed_kits(Path.join(@samples, "Kits.xlsx"))

      assert Repo.aggregate(Kit, :count) == 5
    end
  end

  defp catalog_path do
    Path.join(@samples, "Tabela_padrão_-_suprimentos_médicos_Missão_de_4_mesas.xlsx")
  end
end
