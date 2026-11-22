defmodule EstoqueOSWeb.GettextTest do
  @moduledoc """
  The merge writes a similar existing translation into a new entry and marks it
  `fuzzy`, but `fuzzy` does not stop it rendering, so the wrong text ships. A
  string never extracted renders in English; `--check-up-to-date` in the
  `precommit` alias catches that case.
  """

  use ExUnit.Case, async: true

  @locales_dir "priv/gettext"

  defp po_files do
    Path.wildcard(Path.join(@locales_dir, "*/LC_MESSAGES/*.po"))
  end

  test "there are translation files to check at all" do
    assert po_files() != []
  end

  test "no entry is left fuzzy" do
    offenders =
      for path <- po_files(),
          {block, index} <- Enum.with_index(blocks(path)),
          String.contains?(block, "#, ") and String.contains?(block, "fuzzy"),
          do: "#{path} (block #{index + 1}): #{msgid(block)}"

    assert offenders == [], """
    A fuzzy entry is a guess the merge made, and it renders as if it were a
    translation. Read each one and either correct it or confirm it, then drop
    the `fuzzy` flag:

    #{Enum.join(offenders, "\n")}
    """
  end

  test "no message is left untranslated" do
    offenders =
      for path <- po_files(),
          block <- blocks(path),
          id = msgid(block),
          id not in [nil, ~s("")],
          untranslated?(block),
          do: "#{path}: #{id}"

    assert offenders == [], """
    An empty msgstr renders the English source to a Portuguese operator:

    #{Enum.join(offenders, "\n")}
    """
  end

  defp blocks(path) do
    path
    |> File.read!()
    |> String.split("\n\n", trim: true)
  end

  defp msgid(block) do
    Regex.run(~r/^msgid (.+)$/m, block, capture: :all_but_first) |> List.first()
  end

  # The header block is `msgid ""`; the caller filters it out by msgid.
  defp untranslated?(block) do
    Regex.match?(~r/^msgstr ""\s*$/m, block) and
      not Regex.match?(~r/^msgstr\[\d\]/m, block)
  end
end
