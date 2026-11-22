defmodule EstoqueOSWeb.Movement do
  @moduledoc """
  How a ledger movement is described on screen, in one place.

  `detail/1` adds what the type alone does not say, per type: a route, a
  destination and goods, a reason, or a supplier.
  """

  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  @doc """
  What kind of event this was, read from the movement itself.

  A purchase without an invoice is a manual entry under the same ledger type;
  only `invoice_id` tells them apart.
  """
  def kind_label(%{type: "purchase_in", invoice_id: nil}), do: gettext("Manual entry")
  def kind_label(%{type: type}), do: label(type)

  @doc "What kind of event this was, from the type alone."
  def label("purchase_in"), do: gettext("Invoice posted")
  def label("donation_in"), do: gettext("Donation received")
  def label("transfer"), do: gettext("Transfer")
  def label("load_out"), do: gettext("Load-out")
  def label("return_in"), do: gettext("Return")
  def label("kit_assembly"), do: gettext("Kit assembled")
  def label("kit_consumption"), do: gettext("Kit consumed")
  def label("manual_out"), do: gettext("Manual issue")
  def label("adjustment"), do: gettext("Adjustment")
  def label("inventory_import"), do: gettext("Count imported")
  def label(other), do: other

  @doc """
  The colour a movement type is drawn in, as a daisyUI badge class.

  Four colours, not ten, grouped by direction:

    * `badge-success` — goods arrived
    * `badge-warning` — goods left for good
    * `badge-info` — goods moved without changing hands
    * `badge-ghost` — the ledger corrected itself; nothing physically moved
  """
  def tone(type) when type in ~w(purchase_in donation_in return_in), do: "badge-success"
  def tone(type) when type in ~w(load_out manual_out kit_consumption), do: "badge-warning"
  def tone(type) when type in ~w(transfer kit_assembly), do: "badge-info"
  def tone(type) when type in ~w(adjustment inventory_import), do: "badge-ghost"
  def tone(_other), do: "badge-ghost"

  attr :type, :string, default: nil, doc: "when only the type is known, as in a grouped report"
  attr :movement, :map, default: nil, doc: "the transaction, which can tell an entry from a note"
  attr :class, :string, default: nil

  def movement_badge(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        if(assigns.movement, do: kind_label(assigns.movement), else: label(assigns.type))
      )

    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", tone(@type || @movement.type), @class]}>
      {@label}
    </span>
    """
  end

  @doc "Why stock changed without goods moving."
  def reason_label("expiry"), do: gettext("expiry")
  def reason_label("damage"), do: gettext("damage")
  def reason_label("loss"), do: gettext("loss")
  def reason_label("count_correction"), do: gettext("count correction")
  def reason_label("other"), do: gettext("other")
  def reason_label(nil), do: "—"

  @doc "Where a manual issue went."
  def destination_label("pacu"), do: gettext("PACU")
  def destination_label("operating_room"), do: gettext("Operating room")
  def destination_label("donation"), do: gettext("Donation")
  def destination_label("pre_and_post"), do: gettext("Pre and post")
  def destination_label("triage"), do: gettext("Triage")
  def destination_label("disposal"), do: gettext("Disposal")
  def destination_label("sale"), do: gettext("Sale")
  def destination_label(nil), do: nil

  @doc "From where to where, for the movements that travel."
  def route(transaction) do
    [transaction.source_location, transaction.destination_location]
    |> Enum.map(&(&1 && &1.name))
    |> case do
      [nil, nil] -> nil
      [from, nil] -> from
      [nil, to] -> "→ #{to}"
      [from, to] -> "#{from} → #{to}"
    end
  end

  @doc """
  The sentence that makes a log line worth reading, or nil when the type adds
  nothing beyond its label.
  """
  def detail(%{type: type} = transaction) when type in ~w(load_out transfer return_in) do
    route(transaction)
  end

  def detail(%{type: "manual_out"} = transaction) do
    [destination_label(transaction.destination), goods(transaction)]
    |> Enum.reject(&is_nil/1)
    |> join()
  end

  def detail(%{type: "adjustment"} = transaction) do
    [reason_label(transaction.reason_code), goods(transaction)]
    |> Enum.reject(&(is_nil(&1) or &1 == "—"))
    |> join()
  end

  def detail(%{type: type} = transaction) when type in ~w(purchase_in donation_in) do
    document(transaction) || transaction.notes
  end

  def detail(%{type: type} = transaction) when type in ~w(kit_assembly kit_consumption) do
    transaction.notes
  end

  def detail(transaction), do: transaction.notes

  @doc """
  The paper that justifies the movement, falling back to free-text notes where
  no document covers it.
  """
  def document(%{invoice: %{number: number, supplier: %{legal_name: name}}}) do
    "NF #{number} · #{name}"
  end

  def document(%{notes: notes}) when is_binary(notes) and notes != "", do: notes
  def document(_transaction), do: nil

  # The products, not the lots: at this altitude the lot is noise.
  defp goods(%{entries: entries}) when is_list(entries) do
    entries
    |> Enum.map(& &1.lot.product.name)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [one] -> one
      [one | rest] -> gettext("%{product} +%{count}", product: one, count: length(rest))
    end
  end

  defp goods(_transaction), do: nil

  defp join([]), do: nil
  defp join(parts), do: Enum.join(parts, " · ")
end
