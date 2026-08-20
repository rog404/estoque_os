defmodule EstoqueOS.SuggestedProductNameTest do
  @moduledoc """
  The cases are the item descriptions from the sample NF-e XMLs in `priv/samples/`,
  not invented ones. Every truncation here is a truncation a supplier actually
  sent.
  """

  use ExUnit.Case, async: true

  alias EstoqueOS.Catalog

  test "drops the shipment tail a supplier appends" do
    assert Catalog.suggested_product_name(
             "AC.TRANEXAMICO 50MG/ML 100AMP 5ML GEN-HIPOLABOR (Fornecedor: 1898, Lote: BD-057/25M, Qtde: 1 ,Data Fab:"
           ) == "AC.TRANEXAMICO 50MG/ML 100AMP 5ML GEN-HIPOLABOR"
  end

  test "handles a tail cut off mid-word, with no closing bracket" do
    assert Catalog.suggested_product_name(
             "BUPIVACAINA S/V 0.5% 25 FRASCO AMPOLA 20ML GEN HOSP-HYPOFARMA (Fornecedor: 4219, Lote: 25071596, Qtde: 2 ,Data"
           ) == "BUPIVACAINA S/V 0.5% 25 FRASCO AMPOLA 20ML GEN HOSP-HYPOFARMA"
  end

  test "keeps a parenthesis that is part of the product name" do
    assert Catalog.suggested_product_name("SUGAMADEX SODICO 100MG/ML (200MG) IV 10 FRASCOS") ==
             "SUGAMADEX SODICO 100MG/ML (200MG) IV 10 FRASCOS"
  end

  test "strips only the shipment parenthesis when both are present" do
    assert Catalog.suggested_product_name(
             "SUGAMADEX SODICO 100MG/ML (200MG) IV 10 FRASCOS AMPOLA GEN-BLAU (Fornecedor: 47, Lote: 26011186, Qtde: 1 ,Data"
           ) == "SUGAMADEX SODICO 100MG/ML (200MG) IV 10 FRASCOS AMPOLA GEN-BLAU"
  end

  test "leaves a clean description alone" do
    assert Catalog.suggested_product_name("CATETER INTRAVENOSO 22G C/100-ZELARA") ==
             "CATETER INTRAVENOSO 22G C/100-ZELARA"
  end

  test "collapses the whitespace suppliers pad with" do
    assert Catalog.suggested_product_name("  ALCOOL   70%   ") == "ALCOOL 70%"
  end

  test "never proposes an empty name, even for a description that is all tail" do
    assert Catalog.suggested_product_name("(Fornecedor: 1, Lote: X, Qtde: 2") ==
             "(Fornecedor: 1, Lote: X, Qtde: 2"
  end

  test "passes nil through" do
    assert Catalog.suggested_product_name(nil) == nil
  end
end
