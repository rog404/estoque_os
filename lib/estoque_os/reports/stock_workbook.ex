defmodule EstoqueOS.Reports.StockWorkbook do
  @moduledoc """
  The stock spreadsheet, in both directions.

  Headers are Portuguese because the file is opened by people, not machines,
  and they double as the import contract: `import_rows/1` looks columns up by
  header name, so a coordinator can reorder or annotate columns and the file
  still imports.
  """

  use Gettext, backend: EstoqueOSWeb.Gettext

  alias Elixlsx.{Sheet, Workbook}

  # {key, header}. Order is the export order.
  @columns [
    {:product, "Produto"},
    {:group, "Grupo"},
    {:lot_number, "Lote"},
    {:expires_on, "Validade"},
    {:box, "Caixa"},
    {:location, "Local"},
    {:quantity, "Quantidade"},
    {:unit_cost, "Custo unitário"},
    {:total, "Total"}
  ]

  @required_on_import [:product, :quantity, :location]
  @money_columns [:unit_cost, :total]

  @doc "Column keys and the headers they are written with."
  def columns, do: @columns

  @doc """
  Builds the XLSX binary for the given stock rows.

  ## Options

    * `:money` — include the cost columns. Defaults to `true`. The logistics
      operator counts stock and sends the file back, so the export cannot simply
      be refused to them; what it can do is leave out what they were never given
      on paper either. Their spreadsheet has always carried description,
      quantity and box and never a price.

  Dropping the columns is safe for the round trip because `import_rows/1` finds
  columns by header name and cost is not required on import — a file exported
  without them comes back in and reads correctly.
  """
  def to_xlsx(rows, opts \\ []) do
    columns = columns_for(opts)
    header = Enum.map(columns, fn {_key, header} -> [header, bold: true] end)

    sheet = %Sheet{
      name: "Estoque",
      rows: [header | Enum.map(rows, &to_row(&1, columns))],
      col_widths: %{1 => 45.0, 2 => 20.0, 3 => 16.0, 4 => 12.0, 6 => 20.0}
    }

    %Workbook{sheets: [sheet]}
    |> Elixlsx.write_to_memory("estoque.xlsx")
    |> case do
      {:ok, {~c"estoque.xlsx", binary}} -> {:ok, binary}
      other -> other
    end
  end

  defp columns_for(opts) do
    if Keyword.get(opts, :money, true) do
      @columns
    else
      Enum.reject(@columns, fn {key, _header} -> key in @money_columns end)
    end
  end

  defp to_row(row, columns) do
    Enum.map(columns, fn {key, _header} -> cell(key, Map.get(row, key)) end)
  end

  defp cell(_key, nil), do: ""
  defp cell(:expires_on, %Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")

  defp cell(key, %Decimal{} = value) when key in [:unit_cost, :total] do
    Decimal.to_float(value)
  end

  defp cell(:quantity, %Decimal{} = value), do: Decimal.to_float(value)

  # A product/group/box/location name is text a supplier or a colleague typed,
  # not text this app wrote. Opened in Excel, a value starting with =, +, - or
  # @ runs as a formula instead of reading as a name — prefixing it with an
  # apostrophe forces text, which Excel then hides from the display.
  defp cell(_key, value) when is_binary(value) do
    if String.starts_with?(value, ["=", "+", "-", "@"]) do
      "'" <> value
    else
      value
    end
  end

  defp cell(_key, value), do: value

  @doc """
  Reads a stock spreadsheet back into rows.

  Returns `{:ok, rows}` where each row carries its 1-based spreadsheet line, so
  errors can point at what the user sees, or `{:error, reason}` when the file
  itself is unusable.
  """
  def import_rows(binary) do
    with {:ok, package} <- XlsxReader.open(binary, source: :binary),
         {:ok, [header | rows]} <- first_sheet(package) do
      case column_index(header) do
        {:error, missing} -> {:error, {:missing_columns, missing}}
        index -> {:ok, rows |> Enum.with_index(2) |> Enum.map(&parse_row(&1, index))}
      end
    else
      {:ok, []} -> {:error, :empty_spreadsheet}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_sheet(package) do
    case XlsxReader.sheet_names(package) do
      [] -> {:error, :empty_spreadsheet}
      [name | _] -> XlsxReader.sheet(package, name, number_type: Decimal, blank_value: nil)
    end
  end

  defp column_index(header) do
    normalized =
      header
      |> Enum.with_index()
      |> Map.new(fn {value, index} -> {normalize(value), index} end)

    index =
      Map.new(@columns, fn {key, label} -> {key, Map.get(normalized, normalize(label))} end)

    case Enum.filter(@required_on_import, &is_nil(index[&1])) do
      [] -> index
      missing -> {:error, Enum.map(missing, &header_for/1)}
    end
  end

  defp header_for(key) do
    {_key, header} = Enum.find(@columns, fn {column, _header} -> column == key end)
    header
  end

  defp normalize(nil), do: ""

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  defp parse_row({cells, line}, index) do
    value = fn key -> index[key] && Enum.at(cells, index[key]) end

    %{
      line: line,
      product: text(value.(:product)),
      group: text(value.(:group)),
      lot_number: text(value.(:lot_number)),
      expires_on: date(value.(:expires_on)),
      box: text(value.(:box)),
      location: text(value.(:location)),
      quantity: decimal(value.(:quantity)),
      unit_cost: decimal(value.(:unit_cost))
    }
  end

  defp text(nil), do: nil
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp text(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value

  defp decimal(value) when is_number(value), do: Decimal.new("#{value}")

  defp decimal(value) do
    case value |> to_string() |> String.trim() |> String.replace(",", ".") |> Decimal.parse() do
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  defp date(nil), do: nil
  defp date(%Date{} = date), do: date
  defp date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp date(value) do
    value = value |> to_string() |> String.trim()

    with :error <- brazilian_date(value),
         {:error, _} <- Date.from_iso8601(value) do
      nil
    else
      {:ok, date} -> date
      %Date{} = date -> date
    end
  end

  defp brazilian_date(value) do
    with [day, month, year] <- String.split(value, "/"),
         {day, ""} <- Integer.parse(day),
         {month, ""} <- Integer.parse(month),
         {year, ""} <- Integer.parse(year),
         {:ok, date} <- Date.new(if(year < 100, do: 2000 + year, else: year), month, day) do
      date
    else
      _ -> :error
    end
  end
end
