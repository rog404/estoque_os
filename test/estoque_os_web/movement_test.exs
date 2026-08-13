defmodule EstoqueOSWeb.MovementTest do
  @moduledoc """
  "A load-out, yes — but from where to where?" The type names the kind of event
  and says nothing about the event, which is what made the recent-activity list
  hard to audit from.

  What is worth adding differs per type, so each type is pinned separately here.
  """

  use ExUnit.Case, async: true

  alias EstoqueOSWeb.Movement

  defp entry(product), do: %{lot: %{product: %{name: product}}}

  test "a load-out says where it went" do
    movement = %{
      type: "load_out",
      source_location: %{name: "Estoque Principal"},
      destination_location: %{name: "Missão Tefé"}
    }

    assert Movement.detail(movement) == "Estoque Principal → Missão Tefé"
  end

  test "a movement with only a source still says something" do
    movement = %{
      type: "transfer",
      source_location: %{name: "Estoque Principal"},
      destination_location: nil
    }

    assert Movement.detail(movement) == "Estoque Principal"
  end

  test "a manual issue says where to and what left" do
    movement = %{
      type: "manual_out",
      destination: "pacu",
      entries: [entry("Gaze"), entry("Gaze"), entry("Fentanila")]
    }

    detail = Movement.detail(movement)

    assert detail =~ "PACU"
    assert detail =~ "Gaze"
    # Two products, listed as one plus a count rather than a wall of names.
    assert detail =~ "+1"
  end

  test "a manual issue with no destination still names the goods" do
    movement = %{type: "manual_out", destination: nil, entries: [entry("Avental")]}

    assert Movement.detail(movement) == "Avental"
  end

  test "an adjustment says the reason somebody typed" do
    movement = %{type: "adjustment", reason_code: "expiry", entries: [entry("Soro")]}

    detail = Movement.detail(movement)

    assert detail =~ "Soro"
    refute detail == "Soro"
  end

  test "a posted invoice says the supplier" do
    movement = %{
      type: "purchase_in",
      invoice: %{number: "977098", supplier: %{legal_name: "Cirúrgica Atlântica"}},
      notes: nil
    }

    assert Movement.detail(movement) == "NF 977098 · Cirúrgica Atlântica"
  end

  test "falls back to the note when there is no document" do
    movement = %{type: "purchase_in", invoice: nil, notes: "Doação recebida"}

    assert Movement.detail(movement) == "Doação recebida"
  end

  test "says nothing rather than something empty" do
    movement = %{type: "load_out", source_location: nil, destination_location: nil}

    assert Movement.detail(movement) == nil
  end

  test "an unknown type is shown as itself, not swallowed" do
    assert Movement.label("something_new") == "something_new"
  end

  describe "tone/1" do
    # Four colours and not ten. What the eye scans a ledger for is direction,
    # and ten colours is a legend nobody memorises.
    test "groups the types by what the goods did" do
      arriving = ~w(purchase_in donation_in return_in)
      leaving = ~w(load_out manual_out kit_consumption)
      moving = ~w(transfer kit_assembly)
      neither = ~w(adjustment inventory_import)

      assert Enum.all?(arriving, &(Movement.tone(&1) == "badge-success"))
      assert Enum.all?(leaving, &(Movement.tone(&1) == "badge-warning"))
      assert Enum.all?(moving, &(Movement.tone(&1) == "badge-info"))
      assert Enum.all?(neither, &(Movement.tone(&1) == "badge-ghost"))
    end

    # A type with a label and no colour would render an unstyled badge, which
    # reads as a fifth meaning rather than as a gap.
    test "every type the ledger can write has a colour" do
      for type <- EstoqueOS.Inventory.Transaction.types() do
        assert Movement.tone(type) in ~w(badge-success badge-warning badge-info badge-ghost),
               "#{type} has no colour"
      end
    end

    test "an unknown type is drawn quietly rather than crashing" do
      assert Movement.tone("something_new") == "badge-ghost"
    end
  end
end
