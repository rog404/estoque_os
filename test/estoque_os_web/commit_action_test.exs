defmodule EstoqueOSWeb.CommitActionTest do
  @moduledoc """
  The last button before an irreversible write must say what it does.

  It said nothing for a while: the component declared `confirm_label` with a
  default and then reached for `assign_new`, which only fires when a key is
  absent. Every caller that did not spell the label out by hand — posting an
  invoice, receiving a mission back, deactivating a location — opened a dialog
  whose confirm button was blank.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EstoqueOSWeb.CoreComponents

  defp dialog(assigns) do
    render_component(&CoreComponents.commit_action/1, assigns)
  end

  test "the confirm button falls back to the trigger's label" do
    html = dialog(%{id: "post", form: "post-form", label: "Lançar no estoque", title: "Lançar?"})

    assert [_trigger, confirm] = submit_texts(html)
    assert confirm == "Lançar no estoque"
  end

  test "an explicit confirm_label wins over the trigger's label" do
    html =
      dialog(%{
        id: "remove",
        form: "remove-form",
        label: "Remover do kit",
        title: "Remover?",
        confirm_label: "Remover"
      })

    assert [_trigger, confirm] = submit_texts(html)
    assert confirm == "Remover"
  end

  # Four screens render this dialog inside a form — the write-off basket, the
  # load-out, the return, the invoice — and the HTML parser drops a nested form
  # outright. The backdrop was one, so on those screens it vanished, taking
  # click-outside-to-close with it, and its bare button was reparented onto the
  # page as a stray "Fechar" sitting in plain view under the dialog. The
  # invariant is cheap to state and invisible in review: this component renders
  # no form of its own.
  test "carries no form of its own, so it survives being rendered inside one" do
    html = dialog(%{id: "post", form: "post-form", label: "Lançar", title: "Lançar?"})

    refute html =~ "<form"
    assert html =~ "modal-backdrop"
  end

  # And the backdrop is a click target, not a labelled control: the word used to
  # be its visible text.
  test "the backdrop is named for a screen reader and says nothing on screen" do
    html = dialog(%{id: "post", form: "post-form", label: "Lançar", title: "Lançar?"})

    [backdrop] = Regex.run(~r{<button[^>]*modal-backdrop[^>]*>[^<]*</button>}, html)

    assert backdrop =~ ~s(aria-label="Fechar")
    assert String.replace(backdrop, ~r{<[^>]*>}, "") |> String.trim() == ""
  end

  test "an icon trigger keeps its label on the confirm button" do
    html =
      dialog(%{
        id: "remove",
        form: "remove-form",
        label: "Remover do kit",
        title: "Remover?",
        icon: "hero-trash"
      })

    # The trigger is a square icon and carries the words as its accessible name;
    # the confirm button still has to spell them out.
    assert html =~ ~s(aria-label="Remover do kit")
    assert "Remover do kit" in submit_texts(html)
  end

  # The trigger and the dialog's confirm button, in document order, with the
  # markup stripped — what somebody actually reads on each.
  defp submit_texts(html) do
    ~r{<button[^>]*>(.*?)</button>}s
    |> Regex.scan(html)
    |> Enum.map(fn [_whole, inner] ->
      inner |> String.replace(~r{<[^>]*>}s, "") |> String.trim()
    end)
    |> Enum.reject(&(&1 in ["", "Cancelar", "Fechar", "Cancel", "Close"]))
  end
end
