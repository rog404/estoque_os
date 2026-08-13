defmodule EstoqueOS.Invoices.Importers.NFe do
  @moduledoc """
  Parser for the Brazilian NF-e, layout 4.00.

  The layout is standardized nationally, so there is one parser rather than one
  per supplier. What actually varies between suppliers is *where the lot data
  hides*, so lot and expiry are looked up in this order:

    1. the structured `rastro` group (MedSul ships it);
    2. a regex over the free text of `infAdProd` (Cirúrgica Atlântica writes
       `| Lote:114391U02, Validade:31/03/27, Quantidade:6` there);
    3. nothing — the item is flagged `needs_review` and a human fills it in.

  `xProd` is capped at 120 characters by the layout, and suppliers let the rest
  spill into `infAdProd` mid-word — MedSul splits `Lote:` from `Data Val:`
  across the two fields. The regexes therefore run over both fields joined
  together, so a value cut in half still reassembles.
  """

  @behaviour EstoqueOS.Invoices.Importer

  import SweetXml

  @no_gtin ~w(SEM GTIN SEMGTIN)

  # Commercial units that are already the individual unit: one CX may hold 250
  # pieces, but one FR is one flask.
  @individual_units ~w(UN UND UNID PC PÇ PECA PEÇA FR FRASCO AMP AMPOLA)

  @lot_pattern ~r/lote\s*:?\s*(?<value>[^,;|\n\r]+)/iu
  @expiry_pattern ~r/(?:validade|data\s*val|val)\s*:?\s*(?<value>\d{1,2}\/\d{1,2}\/\d{2,4})/iu
  @manufactured_pattern ~r/(?:data\s*fab|fabrica[çc][ãa]o|fab)\s*:?\s*(?<value>\d{1,2}\/\d{1,2}\/\d{2,4})/iu

  # Pack sizes as suppliers write them: "C/100", "PT/50", "CX 250",
  # "25 FRASCO AMPOLA", "100AMP", "10 FRASCOS".
  @pack_size_patterns [
    ~r{\b(?:c|cx|pt|pct|emb|env|kit)\s*/\s*(?<value>\d+)\b}iu,
    ~r/\b(?:cx|pt|pct|emb|caixa|pacote)\s*(?:com|c)?\s*[:\s]\s*(?<value>\d+)\b/iu,
    ~r/\b(?<value>\d+)\s*(?:frascos?|ampolas?|amp|comprimidos?|comp|unidades?|unid|un|pe[çc]as?|pcs?)\b/iu
  ]

  @impl true
  def supports?(document) when is_binary(document) do
    String.contains?(document, "infNFe") and String.contains?(document, "portalfiscal.inf.br")
  end

  def supports?(_), do: false

  @impl true
  def parse(document) when is_binary(document) do
    # Every lookup is anchored at the invoice node: a signed NF-e repeats parts
    # of itself (signature, protocol), and an unanchored "//nNF" would happily
    # concatenate the text of every match it finds.
    with {:ok, doc} <- parse_xml(document),
         {:ok, invoice} <- invoice_node(doc),
         {:ok, access_key} <- access_key(invoice),
         {:ok, issued_on} <- issued_on(invoice) do
      {:ok,
       %{
         access_key: access_key,
         number: text(invoice, ~x"./ide/nNF/text()"s),
         series: text(invoice, ~x"./ide/serie/text()"s),
         issued_on: issued_on,
         total: decimal(invoice, ~x"./total/ICMSTot/vNF/text()"s),
         supplier: supplier(invoice),
         items: invoice |> xpath(~x"./det"l) |> Enum.map(&item/1),
         raw_xml: document
       }}
    end
  end

  def parse(_), do: {:error, :invalid_document}

  defp invoice_node(doc) do
    case xpath(doc, ~x"//infNFe"o) do
      nil -> {:error, :missing_access_key}
      node -> {:ok, node}
    end
  end

  @doc """
  Parses a CC-e (correction letter) event so it can be attached to its invoice.
  """
  def parse_event(document) when is_binary(document) do
    with {:ok, doc} <- parse_xml(document) do
      # A CC-e carries the event twice: the one the supplier sent and the one
      # SEFAZ echoed back. Anchor on the first, or the two would run together.
      case xpath(doc, ~x"//infEvento"o) do
        nil ->
          {:error, :not_an_event}

        event ->
          case text(event, ~x"./chNFe/text()"s) do
            nil ->
              {:error, :not_an_event}

            access_key ->
              {:ok,
               %{
                 access_key: access_key,
                 kind: event_kind(text(event, ~x"./tpEvento/text()"s)),
                 sequence: integer(event, ~x"./nSeqEvento/text()"s),
                 occurred_at: datetime(event, ~x"./dhEvento/text()"s),
                 description: text(event, ~x"./detEvento/xCorrecao/text()"s),
                 raw_xml: document
               }}
          end
      end
    end
  end

  @doc """
  Suggests how many stock units fit in one commercial unit, from the pack size
  embedded in the description.

  Always a suggestion: it is confirmed once by a human per product and unit.
  """
  def suggest_conversion_factor(description, commercial_unit)

  def suggest_conversion_factor(nil, unit), do: suggest_conversion_factor("", unit)

  def suggest_conversion_factor(description, commercial_unit) do
    case pack_size(description) do
      nil -> if individual_unit?(commercial_unit), do: Decimal.new(1), else: nil
      size -> Decimal.new(size)
    end
  end

  defp pack_size(description) do
    Enum.find_value(@pack_size_patterns, fn pattern ->
      case Regex.named_captures(pattern, description) do
        %{"value" => value} -> if value == "0", do: nil, else: value
        nil -> nil
      end
    end)
  end

  defp individual_unit?(nil), do: false

  defp individual_unit?(unit) do
    unit |> String.trim() |> String.upcase() |> Kernel.in(@individual_units)
  end

  defp item(det) do
    number = det |> xpath(~x"./@nItem"s) |> parse_integer()
    description = text(det, ~x"./prod/xProd/text()"s) || ""
    additional_info = text(det, ~x"./infAdProd/text()"s)
    commercial_unit = text(det, ~x"./prod/uCom/text()"s)

    {lot, lot_source, several_lots?} = lot(det, description, additional_info)

    %{
      item_number: number,
      supplier_product_code: text(det, ~x"./prod/cProd/text()"s),
      gtin: gtin(det),
      description: description,
      ncm: text(det, ~x"./prod/NCM/text()"s),
      anvisa_code: text(det, ~x"./prod/med/cProdANVISA/text()"s),
      commercial_unit: commercial_unit,
      commercial_quantity: decimal(det, ~x"./prod/qCom/text()"s),
      commercial_unit_value: decimal(det, ~x"./prod/vUnCom/text()"s),
      total_value: decimal(det, ~x"./prod/vProd/text()"s),
      additional_info: additional_info,
      lot_number: lot.lot_number,
      manufactured_on: lot.manufactured_on,
      expires_on: lot.expires_on,
      lot_source: lot_source,
      needs_review: lot_source == "none" or several_lots?,
      suggested_conversion_factor: suggest_conversion_factor(description, commercial_unit)
    }
  end

  # 1. The structured group, when the supplier bothers to send it.
  defp lot(det, description, additional_info) do
    case xpath(det, ~x"./prod/rastro"l) do
      [] ->
        lot_from_free_text(description, additional_info)

      [rastro | rest] ->
        lot = %{
          lot_number: text(rastro, ~x"./nLote/text()"s),
          manufactured_on: iso_date(rastro, ~x"./dFab/text()"s),
          expires_on: iso_date(rastro, ~x"./dVal/text()"s)
        }

        # One invoice line may span several lots. We take the first and let a
        # human split the quantity rather than guessing how it divides.
        {lot, "rastro", rest != []}
    end
  end

  # 2. Free text. Both fields are searched joined together because suppliers
  # let the description overflow from xProd into infAdProd mid-sentence.
  defp lot_from_free_text(description, additional_info) do
    text = [description, additional_info] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    lot = %{
      lot_number: text |> capture(@lot_pattern) |> normalize_lot_number(),
      manufactured_on: text |> capture(@manufactured_pattern) |> brazilian_date(),
      expires_on: text |> capture(@expiry_pattern) |> brazilian_date()
    }

    # 3. Nothing usable: flag it instead of inventing a lot.
    if lot.lot_number || lot.expires_on do
      {lot, "inf_ad_prod", false}
    else
      {%{lot_number: nil, manufactured_on: nil, expires_on: nil}, "none", false}
    end
  end

  defp normalize_lot_number(nil), do: nil

  defp normalize_lot_number(value) do
    # Free text runs on: "Lote: 25071596, Qtde: 2" and "Lote:114391U02" both
    # end at the first separator, but a trailing "Qtde" fragment can survive.
    value
    |> String.split(~r/\s{2,}|\bqtde\b|\bquantidade\b/iu, parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      lot -> lot
    end
  end

  defp capture(text, pattern) do
    case Regex.named_captures(pattern, text) do
      %{"value" => value} -> value
      nil -> nil
    end
  end

  defp gtin(det) do
    value = text(det, ~x"./prod/cEAN/text()"s) || text(det, ~x"./prod/cEANTrib/text()"s)

    cond do
      is_nil(value) -> nil
      String.upcase(value) in @no_gtin -> nil
      not Regex.match?(~r/^\d+$/, value) -> nil
      true -> value
    end
  end

  defp supplier(invoice) do
    %{
      cnpj: text(invoice, ~x"./emit/CNPJ/text()"s),
      legal_name: text(invoice, ~x"./emit/xNome/text()"s),
      trade_name: text(invoice, ~x"./emit/xFant/text()"s),
      city: text(invoice, ~x"./emit/enderEmit/xMun/text()"s),
      state: text(invoice, ~x"./emit/enderEmit/UF/text()"s),
      phone: text(invoice, ~x"./emit/enderEmit/fone/text()"s),
      email: text(invoice, ~x"./emit/email/text()"s)
    }
  end

  defp access_key(invoice) do
    case text(invoice, ~x"./@Id"s) do
      nil ->
        {:error, :missing_access_key}

      id ->
        case String.replace(id, ~r/\D/, "") do
          <<key::binary-size(44)>> -> {:ok, key}
          _ -> {:error, :invalid_access_key}
        end
    end
  end

  defp issued_on(invoice) do
    issued = text(invoice, ~x"./ide/dhEmi/text()"s) || text(invoice, ~x"./ide/dEmi/text()"s)

    case issued && Date.from_iso8601(String.slice(issued, 0, 10)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :missing_issue_date}
    end
  end

  defp parse_xml(document) do
    # dtd: :none blocks XXE and entity expansion; quiet: true keeps xmerl from
    # writing attacker-supplied fragments into the logs on every bad upload.
    {:ok, SweetXml.parse(document, dtd: :none, quiet: true)}
  rescue
    _ -> {:error, :malformed_xml}
  catch
    :exit, _ -> {:error, :malformed_xml}
  end

  defp event_kind("110110"), do: "cce"
  defp event_kind("110111"), do: "cancellation"
  defp event_kind(_), do: "other"

  defp text(node, path) do
    case xpath(node, path) do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  defp decimal(node, path) do
    case text(node, path) do
      nil ->
        nil

      value ->
        case Decimal.parse(value) do
          {decimal, _rest} -> decimal
          :error -> nil
        end
    end
  end

  defp integer(node, path) do
    case text(node, path) do
      nil -> nil
      value -> parse_integer(value)
    end
  end

  # Supplier XML is untrusted input: a non-numeric nItem or nSeqEvento must
  # come back as a parse failure, not as an exception that kills the upload.
  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp iso_date(node, path) do
    with value when is_binary(value) <- text(node, path),
         {:ok, date} <- Date.from_iso8601(String.slice(value, 0, 10)) do
      date
    else
      _ -> nil
    end
  end

  defp datetime(node, path) do
    with value when is_binary(value) <- text(node, path),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      DateTime.truncate(datetime, :second)
    else
      _ -> nil
    end
  end

  # Two-digit years are the norm on Cirúrgica Atlântica invoices: "31/03/27".
  defp brazilian_date(nil), do: nil

  defp brazilian_date(value) do
    with [day, month, year] <- String.split(value, "/"),
         {day, ""} <- Integer.parse(day),
         {month, ""} <- Integer.parse(month),
         {year, ""} <- Integer.parse(year),
         {:ok, date} <- Date.new(full_year(year), month, day) do
      date
    else
      _ -> nil
    end
  end

  defp full_year(year) when year < 100, do: 2000 + year
  defp full_year(year), do: year
end
