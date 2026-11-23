defmodule EstoqueOSWeb.CommitActionTest do
  @moduledoc """
  The last button before an irreversible write must say what it does.
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

  # Several screens render this dialog inside a form, and the HTML parser drops a
  # nested form, which would orphan the backdrop's button onto the page.
  test "carries no form of its own, so it survives being rendered inside one" do
    html = dialog(%{id: "post", form: "post-form", label: "Lançar", title: "Lançar?"})

    refute html =~ "<form"
    assert html =~ "modal-backdrop"
  end

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

    # The icon trigger carries the words as its accessible name; confirm spells them out.
    assert html =~ ~s(aria-label="Remover do kit")
    assert "Remover do kit" in submit_texts(html)
  end

  # Trigger and confirm button texts in document order, markup stripped.
  defp submit_texts(html) do
    ~r{<button[^>]*>(.*?)</button>}s
    |> Regex.scan(html)
    |> Enum.map(fn [_whole, inner] ->
      inner |> String.replace(~r{<[^>]*>}s, "") |> String.trim()
    end)
    |> Enum.reject(&(&1 in ["", "Cancelar", "Fechar", "Cancel", "Close"]))
  end
end
