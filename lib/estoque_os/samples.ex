defmodule EstoqueOS.Samples do
  @moduledoc """
  Where the sample fiscal documents and spreadsheets live.

  Under `priv/` rather than at the project root, because that is what a release
  packages: the seeds read the standard supply table and the kit sheet, and
  `EstoqueOS.Release.seed/0` has to be able to find them on a server where
  there is no checkout and no working directory to be relative to.

  The documents themselves describe fictional companies. They are real in shape
  — two NF-e in layout 4.00, one with a structured `rastro` group and one with
  lot data only in `infAdProd` free text, plus a CC-e — and that shape is what
  the parser is tested against.
  """

  @doc """
  Absolute path of the samples directory.
  """
  def dir, do: :estoque_os |> :code.priv_dir() |> Path.join("samples")

  @doc """
  Absolute path of a named sample.
  """
  def path(name), do: Path.join(dir(), name)

  @doc """
  Contents of a named sample.
  """
  def read!(name), do: name |> path() |> File.read!()

  @doc """
  The OSI standard supply table: the spreadsheet the product catalog is seeded
  from.
  """
  def catalog_sheet, do: path("Tabela_padrão_-_suprimentos_médicos_Missão_de_4_mesas.xlsx")

  @doc """
  The kit definitions spreadsheet.
  """
  def kits_sheet, do: path("Kits.xlsx")

  @doc """
  The NF-e that ships its lot numbers in the structured `rastro` group.
  """
  def invoice_with_rastro, do: "35260411222333000424550010009770981447856989-nfe.xml"

  @doc """
  The NF-e whose lot numbers are only in `infAdProd` free text.
  """
  def invoice_with_inf_ad_prod, do: "35260455666777000181550040019851671590327796-nfe.xml"

  @doc """
  The correction letter (CC-e) attached to `invoice_with_rastro/0`.
  """
  def correction_letter, do: "1101103526041122233300042455001000977098144785698901-cce.xml"
end
