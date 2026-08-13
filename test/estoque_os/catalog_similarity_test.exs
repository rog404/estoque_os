defmodule EstoqueOS.CatalogSimilarityTest do
  @moduledoc """
  A previous attempt at this system died on supplier naming chaos: the same item
  entered three ways is a catalog nobody can search. The unique index on
  `lower(name)` only catches an exact repeat, which is the one case that never
  happens in practice — people vary the accent, the spacing and the word order.

  So creating a product asks first.
  """

  use EstoqueOS.DataCase, async: true

  import EstoqueOS.CatalogFixtures

  alias EstoqueOS.Catalog

  doctest EstoqueOS.Catalog, only: [normalize_for_match: 1], import: true

  describe "similar_products/2" do
    test "catches the same thing typed differently" do
      product_fixture(%{name: "Gaze estéril 7,5 cm"})

      assert [%{product: found}] = Catalog.similar_products("GAZE ESTERIL 7,5 CM")
      assert found.name == "Gaze estéril 7,5 cm"
    end

    test "catches a different word order" do
      product_fixture(%{name: "Compressa de gaze"})

      assert [%{product: found}] = Catalog.similar_products("Gaze compressa de")
      assert found.name == "Compressa de gaze"
    end

    test "a shared word is not a match on its own" do
      product_fixture(%{name: "Gaze estéril 7,5 cm com raio-x detectável"})

      # "Gaze" alone must not read as the same product, or every gauze in the
      # catalog blocks every other one.
      assert Catalog.similar_products("Gaze") == []
    end

    test "finds nothing in an empty catalog" do
      assert Catalog.similar_products("Qualquer coisa") == []
    end

    test "ignores a product that was deactivated" do
      product = product_fixture(%{name: "Avental descartável EG"})
      {:ok, _} = Catalog.update_product(product, %{active: false})

      assert Catalog.similar_products("Avental descartavel EG") == []
    end

    test "does not match a product against itself when told to skip it" do
      product = product_fixture(%{name: "Cânula de Guedel 90mm"})

      assert Catalog.similar_products("Canula de Guedel 90mm", except_id: product.id) == []
    end
  end

  describe "create_product_checked/2" do
    test "creates when nothing is close" do
      assert {:ok, product} = Catalog.create_product_checked(%{name: "Ursinho de pelúcia"})
      assert product.name == "Ursinho de pelúcia"
    end

    test "refuses and hands back what it found" do
      product_fixture(%{name: "Gaze estéril 7,5 cm"})

      assert {:error, {:similar, [%{product: found, score: score}]}} =
               Catalog.create_product_checked(%{name: "GAZE ESTERIL 7,5 CM"})

      assert found.name == "Gaze estéril 7,5 cm"
      assert score >= 0.6
    end

    test "goes ahead when a human says these really are different" do
      product_fixture(%{name: "Gaze estéril 7,5 cm"})

      assert {:ok, product} =
               Catalog.create_product_checked(%{name: "Gaze estéril 7,5 cm II"},
                 confirmed: true
               )

      assert product.id
    end

    test "a size is not a spelling: two airway sizes are two products" do
      # Real names from the standard supply table. These share eight of nine
      # tokens and used to score 0.89 — the token that tells an infant's airway
      # from an adult's weighed the same as "com". Warning about this pair 161
      # times over is how an operator learns to click the warning away.
      product_fixture(%{name: "TUBO ENDOTRAQUEAL PRE-FORMADO 3.0 MM - COM BALÃO"})

      assert Catalog.similar_products("TUBO ENDOTRAQUEAL PRE-FORMADO 7.0 MM - COM BALÃO") == []
    end

    test "and neither is a gauge, a volume or a suture size" do
      product_fixture(%{name: "AGULHA ESPINHAL PARA RAQUIANESTESIA 22G X 1 1/2"})
      product_fixture(%{name: "FIO DE SUTURA 4-0 MONOCRYL AGULHA PS-2"})

      assert Catalog.similar_products("AGULHA ESPINHAL PARA RAQUIANESTESIA 22G X 3 1/2") == []
      assert Catalog.similar_products("FIO DE SUTURA 4-0 MONOCRYL AGULHA PS-4") == []
    end

    test "finds the duplicate that the noise was hiding" do
      # Both of these are in the ONG's own standard table, differing by one
      # space. The old scoring put them below a hundred and sixty pairs of
      # legitimately different sizes, so nobody was ever going to find it.
      product_fixture(%{name: "TUBO ENDOTRAQUEAL 4.0MM - COM BALAO"})

      assert [%{product: found, score: score}] =
               Catalog.similar_products("TUBO ENDOTRAQUEAL 4.0 MM - COM BALAO")

      assert found.name == "TUBO ENDOTRAQUEAL 4.0MM - COM BALAO"
      assert score == 1.0
    end

    test "the same measurement written two ways is one measurement" do
      # The case this module's own docstring names, which it used to score 0.6
      # against itself: `7,5cm` tore into `7` and `5cm` while `7.5 CM` became
      # `7`, `5`, `cm`.
      product_fixture(%{name: "Gaze Estéril 7,5cm"})

      assert [%{score: 1.0}] = Catalog.similar_products("GAZE ESTERIL 7.5 CM")
    end

    test "a name with no measurement is still compared on its words" do
      # Refusing to compare is not the same as deciding they differ: one side
      # having no number to check means the rule has nothing to say.
      product_fixture(%{name: "Compressa de gaze"})

      assert [%{product: found}] = Catalog.similar_products("compressa gaze")
      assert found.name == "Compressa de gaze"
    end

    test "words still decide when the measurements agree" do
      # Same suture size, different material. Numbers cannot separate these and
      # are not asked to; the word overlap does its ordinary job.
      product_fixture(%{name: "FIO DE SUTURA 4-0 MONOCRYL AGULHA P-3"})

      assert [%{product: found}] =
               Catalog.similar_products("FIO DE SUTURA 4-0 PROLENE AGULHA P-3")

      assert found.name == "FIO DE SUTURA 4-0 MONOCRYL AGULHA P-3"
    end

    test "the unique index still stops a byte-for-byte repeat", %{} do
      product_fixture(%{name: "Ursinho de pelúcia"})

      # Even confirmed: two rows with the same name are never right.
      assert {:error, changeset} =
               Catalog.create_product_checked(%{name: "ursinho de pelúcia"}, confirmed: true)

      assert errors_on(changeset).name
    end
  end
end
