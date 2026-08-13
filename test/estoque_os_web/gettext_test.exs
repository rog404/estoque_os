defmodule EstoqueOSWeb.GettextTest do
  @moduledoc """
  Four screens shipped this project with the wrong words on them.

  The pattern was always the same. A new `gettext(...)` call goes in; the merge
  matches it against a similar existing string, writes that translation, and
  marks the entry `fuzzy`. But `fuzzy` is a note to a translator, not a gate —
  the wrong text renders anyway. "Back to stock" came out as "Voltar para os
  kits"; "Movements" as "Registro de movimentações". Nothing failed. The only
  way to notice was to open the page and read it.

  A string that was never extracted at all fails differently and worse: it
  renders in English to an operator who does not read English.

  These are the gate. `--check-up-to-date` in the `precommit` alias catches the
  second case, at the only moment anyone can still fix it cheaply.
  """

  use ExUnit.Case, async: true

  @locales_dir "priv/gettext"

  defp po_files do
    Path.wildcard(Path.join(@locales_dir, "*/LC_MESSAGES/*.po"))
  end

  test "there are translation files to check at all" do
    # Guards every other test here from passing by finding nothing.
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

  # The header block is `msgid ""` with a populated msgstr spanning lines; real
  # entries are the ones with a non-empty msgid, filtered out by the caller.
  defp untranslated?(block) do
    Regex.match?(~r/^msgstr ""\s*$/m, block) and
      not Regex.match?(~r/^msgstr\[\d\]/m, block)
  end
end
