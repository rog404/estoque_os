defmodule EstoqueOS.Reports.StockWorkbook do
  @moduledoc """
  The stock spreadsheet, in both directions.

  Headers are Portuguese (opened by people) and double as the import contract:
  `import_rows/1` finds columns by header name, so columns may be reordered.
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

  @money_columns [:unit_cost, :total]

  # The count sheet: identity + the current balance (locked, the "before") + an
  # empty Contagem column to fill in the field (the "after"). Only Contagem is
  # read back; a blank Contagem means "not counted".
  @count_columns [
    {:product, "Produto"},
    {:lot_number, "Lote"},
    {:expires_on, "Validade"},
    {:box, "Caixa"},
    {:location, "Local"},
    {:current, "Saldo atual"},
    {:counted, "Contagem"}
  ]

  # Headers recognised on import: the export's own, plus the count sheet's
  # Contagem (read as the quantity) and Saldo atual (ignored — it is the
  # reference the counter reads, not what they typed).
  @import_columns @columns ++ [{:counted, "Contagem"}, {:current, "Saldo atual"}]

  @doc "Column keys and the headers they are written with."
  def columns, do: @columns

  @doc """
  Builds the XLSX binary for the given stock rows.

  ## Options

    * `:money` — include the cost columns (default `true`). Logistics counts
      from this file and may never see prices, so their export omits them; that
      round-trips because cost is not required on import.
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

  @doc """
  Builds a count sheet: every position with its current balance and an empty
  Contagem column.

  Everything but Contagem is shaded, so the one white column is the only thing
  to type in. The shading is a cue, not a lock — correctness comes from the
  import reading Contagem alone (Elixlsx cannot protect cells), so an edit to a
  shaded column is simply ignored.
  """
  def to_count_sheet(rows) do
    header =
      Enum.map(@count_columns, fn
        {:counted, header} -> [header, bold: true, bg_color: "#dcfce7"]
        {_key, header} -> [header, bold: true]
      end)

    sheet = %Sheet{
      name: "Contagem",
      rows: [header | Enum.map(rows, &count_row/1)],
      col_widths: %{1 => 45.0, 2 => 16.0, 3 => 12.0, 5 => 22.0, 6 => 12.0, 7 => 12.0}
    }

    %Workbook{sheets: [sheet]}
    |> Elixlsx.write_to_memory("contagem.xlsx")
    |> case do
      {:ok, {~c"contagem.xlsx", binary}} -> {:ok, binary}
      other -> other
    end
  end

  defp count_row(row) do
    Enum.map(@count_columns, fn
      {:counted, _header} -> ""
      {:current, _header} -> locked(cell(:quantity, Map.get(row, :quantity)))
      {key, _header} -> locked(cell(key, Map.get(row, key)))
    end)
  end

  # Shaded and greyed: "reference only, do not edit".
  defp locked(value), do: [value, bg_color: "#eef2f7", color: "#475569"]

  @doc """
  An example sheet to fill in, showing the conventions: a dated lot, the
  `MIGRACAO` placeholder for an unread lot, and a box-only line registering an
  empty box.
  """
  def template do
    rows = [
      %{
        product: "GAZE ESTÉRIL 7,5CM",
        lot_number: "L2291",
        expires_on: ~D[2027-09-30],
        box: "CX01",
        location: "Missão Porto Velho - RO",
        quantity: Decimal.new(40)
      },
      %{
        product: "AVENTAL CIRÚRGICO EG",
        lot_number: "MIGRACAO",
        expires_on: nil,
        box: "CX01",
        location: "Missão Porto Velho - RO",
        quantity: Decimal.new(20)
      },
      %{
        product: nil,
        lot_number: nil,
        expires_on: nil,
        box: "OR84",
        location: "Missão Porto Velho - RO",
        quantity: nil
      }
    ]

    to_xlsx(rows, money: false)
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

  # Names are typed by others; in Excel a leading =, +, - or @ runs as a formula
  # (CSV injection). An apostrophe prefix forces text and Excel hides it.
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
      Map.new(@import_columns, fn {key, label} -> {key, Map.get(normalized, normalize(label))} end)

    # Product and location are always required; the count number comes from
    # either the stock export's "Quantidade" or the count sheet's "Contagem".
    missing =
      Enum.filter([:product, :location], &is_nil(index[&1])) ++
        if(is_nil(index[:quantity]) and is_nil(index[:counted]), do: [:quantity], else: [])

    case missing do
      [] -> index
      keys -> {:error, Enum.map(keys, &header_for/1)}
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

    # A count sheet carries the "Contagem" column; its value is the quantity,
    # and a blank one means "not counted". Otherwise the quantity is the stock
    # export's own "Quantidade".
    counted_sheet? = not is_nil(index[:counted])
    quantity = if counted_sheet?, do: decimal(value.(:counted)), else: decimal(value.(:quantity))

    %{
      line: line,
      product: text(value.(:product)),
      group: text(value.(:group)),
      lot_number: text(value.(:lot_number)),
      expires_on: date(value.(:expires_on)),
      box: text(value.(:box)),
      location: text(value.(:location)),
      quantity: quantity,
      unit_cost: decimal(value.(:unit_cost)),
      counted_sheet?: counted_sheet?
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
