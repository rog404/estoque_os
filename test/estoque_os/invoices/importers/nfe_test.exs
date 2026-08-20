defmodule EstoqueOS.Invoices.Importers.NFeTest do
  @moduledoc """
  Every assertion here is checked against the two sample invoices in
  `priv/samples/` — fictional companies, real NF-e 4.00 structure.
  They are the two shapes that matter: one supplier ships structured lot data,
  the other buries it in free text.
  """

  use ExUnit.Case, async: true

  alias EstoqueOS.Invoices.Importers.NFe

  @samples EstoqueOS.Samples.dir()

  @medsul "35260411222333000424550010009770981447856989-nfe.xml"
  @atlantica "35260455666777000181550040019851671590327796-nfe.xml"
  @correction_letter "1101103526041122233300042455001000977098144785698901-cce.xml"

  defp sample(name), do: @samples |> Path.join(name) |> File.read!()

  defp parse!(name) do
    {:ok, invoice} = name |> sample() |> NFe.parse()
    invoice
  end

  defp item(invoice, number), do: Enum.find(invoice.items, &(&1.item_number == number))

  describe "supports?/1" do
    test "recognizes both invoices" do
      assert NFe.supports?(sample(@medsul))
      assert NFe.supports?(sample(@atlantica))
    end

    test "rejects anything else" do
      refute NFe.supports?("<html><body>not an invoice</body></html>")
      refute NFe.supports?(:not_even_a_string)
    end
  end

  describe "MedSul invoice (structured rastro group)" do
    setup do: %{invoice: parse!(@medsul)}

    test "reads the header", %{invoice: invoice} do
      assert invoice.access_key == "35260411222333000424550010009770981447856989"
      assert invoice.number == "977098"
      assert invoice.series == "1"
      assert invoice.issued_on == ~D[2026-04-23]
      assert Decimal.equal?(invoice.total, Decimal.new("1979.30"))
    end

    test "reads the supplier", %{invoice: invoice} do
      assert invoice.supplier.cnpj == "11222333000424"
      assert invoice.supplier.legal_name =~ "MEDSUL"
    end

    test "reads all 7 items", %{invoice: invoice} do
      assert length(invoice.items) == 7
      assert Enum.map(invoice.items, & &1.item_number) == [1, 2, 3, 4, 5, 6, 7]
    end

    test "every item carries a GTIN", %{invoice: invoice} do
      gtins = Enum.map(invoice.items, & &1.gtin)

      assert Enum.all?(gtins, &Regex.match?(~r/^\d{13,14}$/, &1))
      assert hd(gtins) == "7898122912584"
    end

    test "takes lot and dates from the rastro group", %{invoice: invoice} do
      bupivacaina = item(invoice, 1)

      assert bupivacaina.lot_source == "rastro"
      assert bupivacaina.lot_number == "25071596"
      assert bupivacaina.manufactured_on == ~D[2025-08-01]
      assert bupivacaina.expires_on == ~D[2027-07-31]
      refute bupivacaina.needs_review
    end

    test "keeps lot numbers that look like anything but a number", %{invoice: invoice} do
      assert item(invoice, 2).lot_number == "BD-057/25M"
      assert item(invoice, 4).lot_number == "XR20250901"
      assert item(invoice, 6).lot_number == "S25K100045"
    end

    test "no item needs review", %{invoice: invoice} do
      assert Enum.all?(invoice.items, &(&1.lot_source == "rastro"))
      refute Enum.any?(invoice.items, & &1.needs_review)
    end

    test "reads unit values at full NF-e precision", %{invoice: invoice} do
      assert Decimal.equal?(item(invoice, 1).commercial_unit_value, Decimal.new("130.5000000000"))
      assert Decimal.equal?(item(invoice, 4).commercial_unit_value, Decimal.new("9.1040000000"))
      assert Decimal.equal?(item(invoice, 5).commercial_unit_value, Decimal.new("16.4842500000"))
      assert Decimal.equal?(item(invoice, 1).total_value, Decimal.new("261.00"))
    end

    test "reads quantities and commercial units", %{invoice: invoice} do
      assert item(invoice, 1).commercial_unit == "CX"
      assert Decimal.equal?(item(invoice, 1).commercial_quantity, Decimal.new("2.0000"))
      assert item(invoice, 4).commercial_unit == "UND"
      assert item(invoice, 5).commercial_unit == "FR"
      assert Decimal.equal?(item(invoice, 5).commercial_quantity, Decimal.new("40.0000"))
    end

    test "reads the ANVISA code of medications", %{invoice: invoice} do
      assert item(invoice, 1).anvisa_code == "1038700530013"
      assert item(invoice, 4).anvisa_code == nil
    end

    test "suggests pack sizes read from the description", %{invoice: invoice} do
      # "BUPIVACAINA S/V 0.5% 25 FRASCO AMPOLA 20ML" sold by the box.
      assert Decimal.equal?(item(invoice, 1).suggested_conversion_factor, Decimal.new(25))
      # "AC.TRANEXAMICO 50MG/ML 100AMP 5ML"
      assert Decimal.equal?(item(invoice, 2).suggested_conversion_factor, Decimal.new(100))
      # "SUGAMADEX ... 10 FRASCOS AMPOLA"
      assert Decimal.equal?(item(invoice, 3).suggested_conversion_factor, Decimal.new(10))
      # "CATETER INTRAVENOSO 22G C/100-ZELARA"
      assert Decimal.equal?(item(invoice, 6).suggested_conversion_factor, Decimal.new(100))
      # Sold by the flask: one commercial unit is already one stock unit.
      assert Decimal.equal?(item(invoice, 5).suggested_conversion_factor, Decimal.new(1))
      assert Decimal.equal?(item(invoice, 4).suggested_conversion_factor, Decimal.new(1))
    end
  end

  describe "Cirúrgica Atlântica invoice (lot data only in infAdProd)" do
    setup do: %{invoice: parse!(@atlantica)}

    test "reads the header", %{invoice: invoice} do
      assert invoice.access_key == "35260455666777000181550040019851671590327796"
      assert invoice.number == "1985167"
      assert invoice.series == "4"
      assert invoice.issued_on == ~D[2026-04-23]
      assert Decimal.equal?(invoice.total, Decimal.new("2326.17"))
      assert invoice.supplier.cnpj == "55666777000181"
    end

    test "reads all 4 items with their GTINs", %{invoice: invoice} do
      assert length(invoice.items) == 4
      assert item(invoice, 1).gtin == "07899780182401"
      assert item(invoice, 2).gtin == "8904450902414"
      assert item(invoice, 3).gtin == "7899780141330"
      assert item(invoice, 4).gtin == "7899780141323"
    end

    test "falls back to the infAdProd regex for every item", %{invoice: invoice} do
      assert Enum.all?(invoice.items, &(&1.lot_source == "inf_ad_prod"))
      refute Enum.any?(invoice.items, & &1.needs_review)
    end

    test "extracts lot and expiry from the free text", %{invoice: invoice} do
      # "| Lote:114391U02, Validade:31/03/27, Quantidade:6"
      assert item(invoice, 1).lot_number == "114391U02"
      assert item(invoice, 1).expires_on == ~D[2027-03-31]

      assert item(invoice, 2).lot_number == "316255320W"
      assert item(invoice, 2).expires_on == ~D[2027-08-01]
    end

    test "two products may share a lot number", %{invoice: invoice} do
      assert item(invoice, 3).lot_number == "FY2507022"
      assert item(invoice, 4).lot_number == "FY2507022"
      assert item(invoice, 3).expires_on == ~D[2030-08-15]
      assert item(invoice, 4).expires_on == ~D[2030-08-15]
    end

    test "expands two-digit years into this century", %{invoice: invoice} do
      assert Enum.all?(invoice.items, &(&1.expires_on.year >= 2027))
    end

    test "reads unit values and quantities", %{invoice: invoice} do
      assert item(invoice, 1).commercial_unit == "PT"
      assert Decimal.equal?(item(invoice, 1).commercial_unit_value, Decimal.new("13.475"))
      assert Decimal.equal?(item(invoice, 1).commercial_quantity, Decimal.new("6.00"))

      assert item(invoice, 4).commercial_unit == "PC"
      assert Decimal.equal?(item(invoice, 4).commercial_unit_value, Decimal.new("7.0757"))
      assert Decimal.equal?(item(invoice, 4).total_value, Decimal.new("707.57"))
    end

    test "suggests pack sizes", %{invoice: invoice} do
      # "ELETRODO ECG ADULTO PT/50 POLYMED"
      assert Decimal.equal?(item(invoice, 1).suggested_conversion_factor, Decimal.new(50))
      # Sold by the piece: no packaging to divide.
      assert Decimal.equal?(item(invoice, 2).suggested_conversion_factor, Decimal.new(1))
      assert Decimal.equal?(item(invoice, 3).suggested_conversion_factor, Decimal.new(1))
    end

    test "the derived unit cost is what the coordinator does by hand today", %{invoice: invoice} do
      eletrodo = item(invoice, 1)

      unit_cost =
        Decimal.div(eletrodo.commercial_unit_value, eletrodo.suggested_conversion_factor)

      assert Decimal.equal?(Decimal.round(unit_cost, 4), Decimal.new("0.2695"))
    end
  end

  describe "parse_event/1" do
    test "reads the correction letter and the invoice it belongs to" do
      assert {:ok, event} = @correction_letter |> sample() |> NFe.parse_event()

      assert event.kind == "cce"
      assert event.access_key == "35260411222333000424550010009770981447856989"
      assert event.sequence == 1
      assert is_binary(event.description)
    end

    test "rejects a regular invoice" do
      assert {:error, :not_an_event} = @medsul |> sample() |> NFe.parse_event()
    end
  end

  describe "failure modes" do
    test "malformed XML is reported, never raised" do
      assert {:error, :malformed_xml} = NFe.parse("<nfeProc><unclosed>")
    end

    test "an invoice without an access key is rejected" do
      assert {:error, :missing_access_key} = NFe.parse("<nfeProc><NFe/></nfeProc>")
    end
  end

  describe "suggest_conversion_factor/2" do
    test "reads the pack sizes suppliers actually write" do
      cases = [
        {"CATETER INTRAVENOSO 22G C/100-ZELARA", "CX", 100},
        {"ELETRODO ECG ADULTO PT/50 POLYMED", "PT", 50},
        {"LUVA CIRURGICA CX 250", "CX", 250},
        {"BUPIVACAINA 25 FRASCO AMPOLA 20ML", "CX", 25},
        {"AC.TRANEXAMICO 100AMP 5ML", "CX", 100},
        {"SUGAMADEX 10 FRASCOS AMPOLA", "CX", 10}
      ]

      for {description, unit, expected} <- cases do
        assert Decimal.equal?(
                 NFe.suggest_conversion_factor(description, unit),
                 Decimal.new(expected)
               ),
               "expected #{expected} for #{description}"
      end
    end

    test "an individual commercial unit converts one to one" do
      assert Decimal.equal?(
               NFe.suggest_conversion_factor("CANETA DE BISTURI DESC. EST.", "UND"),
               Decimal.new(1)
             )
    end

    test "asks a human when the packaging cannot be read" do
      assert NFe.suggest_conversion_factor("MALHA TUBULAR ORTOPEDICA", "CX") == nil
      assert NFe.suggest_conversion_factor(nil, "CX") == nil
    end
  end
end
