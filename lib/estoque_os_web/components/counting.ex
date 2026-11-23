defmodule EstoqueOSWeb.Counting do
  @moduledoc """
  Shared counting rules for the conference, box count and mission return.

    * **Blank and blind.** The expected number is not shown, or the eye stops at
      the answer it was given and the count measures nothing.
    * **Blank means not counted, never zero.**
    * **A manager may reveal the expected figure on purpose**; the fact is
      recorded so the count never later reads as blind.

  The flow is not shared: a conference saves per line, a box submits as a
  sheet, and a mission-return divergence usually means goods were used, so it
  is recorded rather than recounted.
  """

  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  import EstoqueOSWeb.CoreComponents, only: [button: 1]
  import EstoqueOSWeb.UI, only: [status: 1]

  @doc """
  The one field somebody types a count into.

  Blank unless a value is carried across a re-render: `phx-change` repaints on
  every keystroke, and a field without a server-rendered value comes back empty.
  """
  attr :name, :string, required: true
  # Empty string, not nil: nil renders no `value` attribute at all.
  attr :value, :any, default: ""
  attr :label, :string, required: true, doc: "the accessible name, naming the line"
  attr :disabled, :boolean, default: false
  attr :rest, :global

  def count_field(assigns) do
    ~H"""
    <input
      type="text"
      name={@name}
      value={@value || ""}
      inputmode="decimal"
      data-numeric
      placeholder={gettext("not counted")}
      disabled={@disabled}
      class="input input-sm input-bordered w-24 text-right"
      aria-label={@label}
      {@rest}
    />
    """
  end

  @doc """
  The manager's exception: show what the ledger expects.

  A button while available, a mark once taken, so the screen carries the fact.
  """
  attr :available?, :boolean, required: true, doc: "the role may reveal, and has not yet"
  attr :revealed?, :boolean, required: true

  def reveal_expected(assigns) do
    ~H"""
    <.button :if={@available?} phx-click="reveal" class="btn-sm">
      {gettext("Show what the ledger expects")}
    </.button>
    <.status :if={@revealed?} kind={:presumed} detail={gettext("expected shown")} />
    """
  end

  @doc """
  Why a line is being counted again: names the items, never the gap, which
  would answer the question the recount exists to ask.
  """
  attr :count, :integer, required: true
  attr :class, :any, default: nil

  def recount_notice(assigns) do
    ~H"""
    <div class={["alert alert-warning flex-col items-start gap-1", @class]}>
      <p class="font-semibold">
        {gettext("%{count} item(s) did not match. Please count these again.", count: @count)}
      </p>
      <p class="text-sm">
        {gettext(
          "A first count that disagrees is as often a miscount as a real loss, and the box is still open."
        )}
      </p>
    </div>
    """
  end

  def blank_note(assigns) do
    ~H"""
    <p class="text-sm opacity-70">
      {gettext("Blank lines are not counted and keep what the ledger presumed.")}
    </p>
    """
  end
end
