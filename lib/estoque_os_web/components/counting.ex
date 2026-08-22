defmodule EstoqueOSWeb.Counting do
  @moduledoc """
  Counting things, the same way everywhere.

  Three screens ask somebody to count: the receiving conference against an
  invoice, the box count, and the mission return. They had grown three different
  answers to the same questions — how wide is the field, what does an empty one
  mean, is the expected number on screen, what happens when the count disagrees
  — and the differences were not decisions. They were the order the screens were
  written in.

  What is shared here is the part that has a right answer:

    * **The field is blank and blind.** Shown the expected number, a person
      counting a hundred gauzes finds ninety-eight and writes a hundred — not
      dishonestly, but because the eye stops when it reaches the answer it was
      given. A count that confirms the ledger it was copied from measures
      nothing. This was already the rule on two screens and the exact opposite
      on the third: the mission return printed what the ledger expected *and*
      typed it into the box for you, on the one screen where the ledger is
      least trustworthy, because after a mission it is a hypothesis.

    * **Blank means not counted, never zero.** Recording an uncounted line as
      zero is how a stock becomes fiction.

    * **The expected figure can be revealed, by a manager, on purpose.** Off by
      default, theirs alone, and the fact that it was taken is recorded — a
      count made with the answer in view must never later read as a blind one.

  What is *not* shared is the flow, because the flows differ for reasons. A
  conference is filled in over hours, line by line, as boxes are opened, so it
  saves per line. A box is counted in one go, so it submits as a sheet. And a
  divergence means different things: on a box count it is as likely a miscount
  as a loss, and the cheapest moment to tell them apart is while the box is
  still open — hence the recount. On a mission return it usually means the
  goods were *used*, which is not a mistake to correct but a fact to record, so
  demanding a recount there would be theatre.
  """

  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  import EstoqueOSWeb.CoreComponents, only: [button: 1]
  import EstoqueOSWeb.UI, only: [status: 1]

  @doc """
  The one field somebody types a count into.

  Always the same width, so a column of them is a column. Always blank unless a
  value is being carried across a re-render — `phx-change` repaints these forms
  on every keystroke, and a field rendered without a value comes back empty
  under the person typing into it.
  """
  attr :name, :string, required: true
  # Empty string and not nil: nil renders no `value` attribute at all, and a
  # reader cannot tell that from somebody having forgotten one. The issue screen
  # learned this the hard way when a repaint blanked a field mid-keystroke.
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

  Rendered as a button while it is available and as a mark once it is taken, so
  the screen carries the fact for as long as the count lasts. Both states are in
  the same slot — a control that disappears on click moves whatever was under
  it.
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
  Why a line is being counted again, naming the items and never the gap.

  Naming the gap would answer the question the second count exists to ask.
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

  @doc """
  What an empty field means, said once per sheet rather than guessed at.
  """
  def blank_note(assigns) do
    ~H"""
    <p class="text-sm opacity-70">
      {gettext("Blank lines are not counted and keep what the ledger presumed.")}
    </p>
    """
  end
end
