defmodule EstoqueOSWeb.UI do
  @moduledoc """
  The design system: the shapes every screen is built from.

  `CoreComponents` holds what Phoenix generates — flashes, form inputs, the
  icon helper. This module holds what this operation decided, and it exists
  because the alternative had been running for a while: twenty-six screens
  spelling a panel four different ways, `card bg-base-100 border border-base-300`
  written out fifty times, a `stat_card` on the dashboard that did not know
  about the `stat` in the component library, and thirty-seven badges whose
  colour was chosen one at a time.

  Three rules hold it together.

  **A status has one spelling.** `status/1` owns the whole vocabulary — expired,
  expiring, controlled, presumed, counted, in transit, incomplete. A screen
  names the state; it does not pick a colour. This is the rule the ledger cares
  about: "presumed" must look the same on every screen or it stops meaning
  anything.

  **Section colour and status colour never meet at the same scale.** A section
  is a field — a tinted band, a rail, a nav underline. A status is a mark — a
  badge, a word, a border on one row. Green and red are the ledger's answers and
  are never spent on navigation.

  **The container is `panel/1`.** One border, one radius, one shadow, one way to
  hold a title. A screen that needs a box uses this one.
  """

  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  import EstoqueOSWeb.CoreComponents, only: [icon: 1]

  @doc """
  The page header: what this screen is, and what you can do here.

  Tinted with the hue of whatever section of the operation the screen belongs
  to, and given a spine by the rail. The hue is inherited from a `data-section`
  the layout puts on its wrapper, so this component never has to be told where
  it is — one call in a screen, and Incoming reads cyan while Reports reads
  gold.

  The name and the slots are the ones the twenty-six screens already use.
  """
  attr :class, :any, default: nil

  attr :back_to, :string,
    default: nil,
    doc: """
    where "up" is from this screen. Rendered above the title, because that is
    where every screen in the app that has one puts it.

    The kit screen had a "Voltar para kits" link at the bottom of a 537-line
    page and was reported as missing it. Unfindable and absent are the same
    thing to the person looking.
    """

  attr :back_label, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <!-- `items-start` and a floor on the height, so the title lands in the same
         place on all twenty-six screens. With `items-end` it sank whenever a
         screen had no subtitle or a tall button beside it, and a heading that
         moves between pages reads as twenty-six layouts rather than one. The
         floor fits a title plus a subtitle, so the content below starts at the
         same line either way. -->
    <header class={["page-head px-4 sm:px-5 py-4", @class]}>
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3 min-h-[3.5rem]">
        <div class="flex items-stretch gap-3 min-w-0">
          <div class="section-rail w-1 shrink-0" aria-hidden="true" />
          <div class="min-w-0">
            <!-- A ghost button, not a quiet inline link: every other control
                 on this screen gets a visible hover box the moment a pointer
                 or a finger is over it, and the one control every screen
                 shares had been the exception. `-ml-3` cancels the button's
                 own padding so the label still lines up with the title under
                 it — the button grows outward from the text, not from the
                 rail beside it. -->
            <.link
              :if={@back_to}
              navigate={@back_to}
              class="btn btn-ghost btn-sm -ml-3 mb-1 text-base-content/70 hover:text-base-content"
            >
              <.icon name="hero-arrow-left" class="size-4" />{@back_label}
            </.link>
            <h1 class="text-2xl font-semibold leading-tight">
              {render_slot(@inner_block)}
            </h1>
            <p :if={@subtitle != []} class="text-sm text-base-content/70 mt-1">
              {render_slot(@subtitle)}
            </p>
          </div>
        </div>

        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </header>
    """
  end

  @doc """
  The container. One border, one radius, one shadow.

  `flush` is for a panel whose whole body is a table: the cells carry their own
  padding and a second inset makes the columns look inset from nothing.
  """
  attr :title, :string, default: nil
  attr :note, :string, default: nil
  attr :flush, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true
  slot :actions

  def panel(assigns) do
    ~H"""
    <section class={["panel", @class]} {@rest}>
      <header :if={@title} class="panel-head">
        <div class="min-w-0 flex-1">
          <h2 class="font-semibold leading-tight truncate">{@title}</h2>
          <p :if={@note} class="text-sm text-base-content/70 font-normal">{@note}</p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2 shrink-0">
          {render_slot(@actions)}
        </div>
      </header>

      <div class={["panel-body", @flush && "is-flush"]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  One number the screen is worth knowing by.

  The value carries the font's proportional figures on purpose: `tabular-nums`
  gives every digit the width of a zero, which reads loose at this size. It
  belongs in the tables, where columns must line up, and not here.

  `tone` tints the number when it is the kind of number somebody should act on.
  A count of nothing-to-do stays neutral: colouring a zero red teaches people to
  ignore red.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, default: nil
  attr :tone, :atom, default: :neutral, values: [:neutral, :good, :warn, :bad]

  attr :money, :boolean,
    default: false,
    doc: "the value is an amount, and follows the eye in the bar"

  attr :dense, :boolean,
    default: false,
    doc: """
    smaller type and less padding, for a screen carrying four or five of these
    above the thing they describe. The 3xl figure is right when the tile is the
    point of the page and wrong when it is a caption on the way to the table.
    """

  def stat(assigns) do
    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      class={[
        "panel flex flex-col gap-0.5 transition hover:border-primary/60 hover:shadow-md",
        if(@dense, do: "px-3 py-2", else: "px-4 py-3")
      ]}
    >
      <.stat_face
        label={@label}
        value={@value}
        hint={@hint}
        icon={@icon}
        tone={@tone}
        money={@money}
        dense={@dense}
      />
    </.link>

    <div
      :if={is_nil(@href)}
      class={["panel flex flex-col gap-0.5", if(@dense, do: "px-3 py-2", else: "px-4 py-3")]}
    >
      <.stat_face
        label={@label}
        value={@value}
        hint={@hint}
        dense={@dense}
        icon={@icon}
        tone={@tone}
        money={@money}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: nil
  attr :tone, :atom, default: :neutral
  attr :money, :boolean, default: false
  attr :dense, :boolean, default: false

  defp stat_face(assigns) do
    ~H"""
    <p class="eyebrow text-base-content/60 flex items-center gap-1.5">
      <.icon :if={@icon} name={@icon} class="size-3.5" />
      {@label}
    </p>
    <p class={[
      "font-semibold leading-none mt-1",
      if(@dense, do: "text-xl", else: "text-3xl"),
      stat_tone(@tone)
    ]}>
      <.amount :if={@money} value={@value} />
      <span :if={not @money}>{@value}</span>
    </p>
    <p :if={@hint} class="text-xs text-base-content/60 mt-1">{@hint}</p>
    """
  end

  defp stat_tone(:good), do: "text-success"
  defp stat_tone(:warn), do: "text-warning"
  defp stat_tone(:bad), do: "text-error"
  defp stat_tone(_neutral), do: nil

  @doc """
  "There is no box AN02 here — create it?"

  Sits under the field the code was typed into, never at the top of the page:
  it was a banner above forty rows once, asking about a box typed somewhere off
  screen, and answering it meant finding the line again.

  The failure it prevents is a code that looks right at a glance. One character
  wrong makes a box that exists, is empty, and is never opened again — and the
  warehouse is then organised by whoever was holding the scanner.

  "No" is the loud button. The typo is the likely case by a wide margin, and
  the cost of the two answers is not symmetric: fixing a code costs a moment,
  and a phantom box is found months later by somebody looking for goods that
  are not in it.
  """
  attr :code, :string,
    default: nil,
    doc: "the one code that does not exist yet. Use `codes` when a form can name several."

  attr :codes, :list,
    default: nil,
    doc: """
    several codes at once, for the screens that submit many lines together. A
    return can name forty boxes and invent three of them, and the operator has
    to see all three before any of them exist.
    """

  attr :confirm, :string, default: "confirm_new_box"
  attr :cancel, :string, default: "cancel_new_box"
  attr :class, :any, default: nil
  attr :rest, :global

  def new_box_confirm(assigns) do
    ~H"""
    <div class={["rounded-box border border-warning/50 bg-warning/10 p-2", @class]}>
      <p :if={@code} class="text-sm font-semibold">
        {gettext("Create box %{code}?", code: @code)}
      </p>
      <p :if={@codes} class="text-sm font-semibold">
        {gettext("Create %{count} box(es): %{codes}?",
          count: length(@codes),
          codes: Enum.join(@codes, ", ")
        )}
      </p>
      <p class="text-xs opacity-80">
        {gettext("No box with that code exists here. Check it is not a typo.")}
      </p>
      <div class="mt-2 flex flex-wrap gap-2">
        <button
          id="confirm-new-box"
          type="button"
          phx-click={@confirm}
          class="btn btn-xs btn-ghost"
          {@rest}
        >
          {gettext("Yes, create it")}
        </button>
        <button
          id="cancel-new-box"
          type="button"
          phx-click={@cancel}
          class="btn btn-xs btn-primary"
          {@rest}
        >
          {gettext("No, let me fix the code")}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The status vocabulary. Every state the stock can be in, spelled one way.

  A screen names the state and gets the colour, the icon and the Portuguese for
  free. This is deliberately a closed list: a state that is not here is a state
  nobody agreed on yet, and adding it is a decision made once, here, rather than
  a colour picked in a template at midnight.

      <.status kind={:expired} />
      <.status kind={:expiring} detail={gettext("20 day(s)")} />
      <.status kind={:presumed} />
  """
  attr :kind, :atom,
    required: true,
    values: [
      :expired,
      :expiring,
      :controlled,
      :presumed,
      :counted,
      :recount,
      :in_transit,
      :under_way,
      :unboxed,
      :not_linked,
      :complete,
      :below_minimum,
      :needs_review,
      :donation,
      :bought,
      :unknown_value,
      :pending
    ]

  attr :detail, :string, default: nil, doc: "shown instead of the standard label"
  attr :class, :any, default: nil

  def status(assigns) do
    assigns = assign(assigns, :spec, status_spec(assigns.kind))

    ~H"""
    <span class={["badge badge-sm gap-1 whitespace-nowrap", @spec.class, @class]}>
      <.icon :if={@spec.icon} name={@spec.icon} class="size-3" />
      {@detail || @spec.label}
    </span>
    """
  end

  # Colour is assigned by what the state *means to the operation*, not by how
  # alarming the word sounds — and now so is the *register*.
  #
  # Two registers, and the choice between them is the design decision, not the
  # hue. A state that describes the goods (bought, donated, controlled,
  # presumed, no box, in transit) is background: `is-quiet` paints it as a dot
  # and a word, so the quantity beside it stays the loudest thing on the row.
  # A state that means *something is wrong now* (expired, a count that
  # disagreed twice, stock under a mission's minimum) keeps the fill, because
  # an alarm that fires on nine rows in ten is not an alarm.
  #
  # Controlled is the one worth explaining: a Portaria 344 substance is not a
  # problem and not a warning — it is a legal class that changes who may touch
  # the box. Quiet, with ink for a dot rather than a hue, so it never reads as
  # "something went wrong" and never blends into the amber of an expiry date.
  defp status_spec(:expired),
    do: %{class: "badge-error", icon: nil, label: gettext("expired")}

  defp status_spec(:expiring),
    do: %{class: "badge-warning", icon: nil, label: gettext("expiring")}

  defp status_spec(:controlled),
    do: %{
      class: "is-quiet dot-neutral",
      icon: nil,
      label: gettext("controlled")
    }

  # Outlined rather than ghost, and never on the stock table. "Presumed" was a
  # 10px ghost badge there once and became the least visible thing on a screen
  # whose whole claim is that it separates counted from inherited; that screen
  # says it in words now, and a test holds it. This spelling is for the places
  # where one row *is* the subject — a box, a single position — and a mark on it
  # is enough.
  defp status_spec(:presumed),
    do: %{
      class: "is-quiet dot-muted",
      icon: nil,
      label: gettext("presumed")
    }

  defp status_spec(:counted),
    do: %{class: "is-quiet dot-success", icon: nil, label: gettext("counted")}

  # A count that was made and not believed, so it is being asked for again. Not
  # an error and not the operator's fault: the first count disagreeing with the
  # invoice is more often a miscount than a loss, and this is the state of
  # finding out which.
  defp status_spec(:recount),
    do: %{class: "badge-warning", icon: nil, label: gettext("count again")}

  defp status_spec(:under_way),
    do: %{class: "is-quiet dot-info", icon: nil, label: gettext("under way")}

  # Loose stock is legitimate — it is what has not been put away yet — but it
  # cannot travel, so it is the operator's next job rather than an error.
  defp status_spec(:unboxed),
    do: %{class: "is-quiet dot-warning", icon: nil, label: gettext("no box")}

  defp status_spec(:not_linked),
    do: %{
      class: "badge-warning",
      icon: nil,
      label: gettext("not linked")
    }

  defp status_spec(:in_transit),
    do: %{class: "is-quiet dot-info", icon: nil, label: gettext("in transit")}

  defp status_spec(:complete),
    do: %{class: "is-quiet dot-success", icon: nil, label: gettext("complete")}

  defp status_spec(:below_minimum),
    do: %{
      class: "badge-warning",
      icon: nil,
      label: gettext("below minimum")
    }

  defp status_spec(:needs_review),
    do: %{
      class: "badge-warning",
      icon: nil,
      label: gettext("needs review")
    }

  defp status_spec(:donation),
    do: %{class: "is-quiet dot-accent", icon: nil, label: gettext("donation")}

  # Ghost, unlike its opposite. Most of the warehouse was bought, and a badge
  # that is on nine rows in ten has stopped saying anything — what the eye is
  # actually looking for is the donation, which is the row with no price and
  # different paperwork.
  defp status_spec(:bought),
    do: %{class: "is-quiet dot-muted", icon: nil, label: gettext("bought")}

  defp status_spec(:unknown_value),
    do: %{class: "is-quiet dot-muted", icon: nil, label: gettext("value not informed")}

  defp status_spec(:pending),
    do: %{class: "badge-warning", icon: nil, label: gettext("pending")}

  @doc """
  A box code, the way the warehouse says it.

  AN01. PR03. JP04 — written on corrugated cardboard in marker pen, shouted
  across a room, read off a shelf from three metres away. It is the one
  identifier this operation says out loud all day, and on screen it was plain
  body text in the middle of a sentence.

  One object, everywhere a box appears, so the thing you can point at on the
  shelf looks like one thing on the screen too.

  Loose stock passes `nil` and gets the same slot with the opposite treatment:
  "sem caixa" is a real and temporary state — goods arrived and nobody has put
  them away yet — not a missing value, and it is somebody's next job.
  """
  attr :code, :string, default: nil
  attr :class, :any, default: nil

  def box_code(assigns) do
    ~H"""
    <span :if={@code} class={["box-code", @class]}>{@code}</span>
    <span :if={is_nil(@code)} class={["box-code is-none", @class]}>{gettext("no box")}</span>
    """
  end

  @doc """
  An amount of money, hideable from whoever is standing behind you.

  Two spans and one of them is displayed, rather than dots positioned over the
  number: a table cell is `display: flex` on a phone and `table-cell` on a
  laptop, and anything built on absolute positioning breaks in one of them.
  Swapping which child is shown works in both, and in prose, and in a stat tile.

  **This is not a security control, and must never be used as one.** The real
  amount is in the markup either way — the toggle is for the coordinator reading
  the screen in a warehouse with people around, which is a different problem
  from the logistics operator who must not receive the number at all. That one
  is answered by not rendering it; see `UserAuth.sees_money?/1`.

  The preference lives in `localStorage` and is applied before first paint, so
  the amounts do not flash on screen while the page loads.
  """
  attr :value, :any, required: true, doc: "already formatted, e.g. `money(row.total)`"
  attr :class, :any, default: nil

  def amount(assigns) do
    ~H"""
    <span class={["money", @class]}>
      <span class="money-real">{@value}</span><span class="money-mask" aria-hidden="true">R$ ••••</span>
    </span>
    """
  end

  @doc """
  A checkbox the size of the field beside it.

  The box itself is 1.5rem and the control around it has the input's exact
  height, border and radius — so in a form grid a checkbox row and a text field
  are the same object, and on a phone the whole row is the tap target rather
  than a 22px square somebody has to aim at while holding a box.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :value, :string, default: "true"
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def check(assigns) do
    ~H"""
    <label class={["check-field", @class]}>
      <input type="checkbox" name={@name} value={@value} checked={@checked} class="checkbox" {@rest} />
      <span class="min-w-0">
        <span class="block truncate leading-tight">{@label}</span>
        <span :if={@hint} class="block text-xs text-base-content/60 leading-tight">{@hint}</span>
      </span>
    </label>
    """
  end

  @doc """
  One filter that takes several answers at once, as chips you tick.

  The native `<select multiple>` was the first attempt and it is the wrong
  control here: it wants a modifier key held down, which the phone this is used
  from does not have, and it shows what is chosen only by highlighting a row
  inside a scrolling box.

  The tone is per *kind* of filter, not per value: places are one colour,
  situations another, and the stock a third — so a row of applied chips says
  what kind of answer each one is before it is read. Pass the same tone to the
  group and to the chips that echo it elsewhere on the page.

  The chips sit in a grid, not in a wrapping row. Wrapped, a chip changes width
  when it is ticked and every chip after it slides to a new place — so the one
  the finger was already over is no longer the one under it. In a grid the cells
  are fixed and a chip can only change colour where it stands.

  Long lists stay usable rather than becoming a wall: the group scrolls at about
  five rows, and above `searchable_from` options it grows a box that narrows the
  chips as you type. The narrowing is done in the browser — a form that
  round-trips on every keystroke is exactly the field that empties itself, which
  is a mistake this codebase has already paid for once.
  """
  attr :name, :string, required: true, doc: ~s(the form field, e.g. `location_id[]`)
  attr :label, :string, required: true
  attr :options, :list, required: true, doc: "`{value, label}` pairs"
  attr :selected, :list, default: [], doc: "the values that are on, as strings"
  attr :tone, :string, default: "primary", values: ~w(primary info accent warning success)

  attr :searchable_from, :integer,
    default: 10,
    doc: "how many options it takes before the group offers a search box"

  def filter_chips(assigns) do
    ~H"""
    <fieldset class={["fieldset w-full filter-chips", "tone-#{@tone}"]}>
      <legend class="label">{@label}</legend>

      <label :if={length(@options) >= @searchable_from} class="input input-sm w-full mb-2">
        <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
        <input
          type="text"
          id={"chip-search-#{chip_id(@name)}"}
          phx-hook=".ChipSearch"
          class="grow"
          placeholder={gettext("Search")}
          aria-label={gettext("Search %{group}", group: @label)}
          autocomplete="off"
        />
      </label>

      <div class="chip-group">
        <label :for={{value, label} <- @options} class="chip-check" data-label={label} title={label}>
          <input
            type="checkbox"
            name={@name}
            value={value}
            checked={to_string(value) in @selected}
            class="sr-only"
          />
          <span>{label}</span>
        </label>
      </div>
    </fieldset>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChipSearch">
      // Narrows the chips beside it, in the browser and nowhere else. A chip
      // that is ticked never hides: what is filtering the list must not vanish
      // because somebody typed a word that does not match it.
      export default {
        mounted() {
          const group = this.el.closest(".filter-chips").querySelector(".chip-group")

          this.el.addEventListener("input", () => {
            const term = this.el.value.trim().toLowerCase()

            group.querySelectorAll(".chip-check").forEach((chip) => {
              const checked = chip.querySelector("input").checked
              const matches = chip.dataset.label.toLowerCase().includes(term)
              chip.hidden = !checked && !matches
            })
          })
        }
      }
    </script>
    """
  end

  defp chip_id(name), do: String.replace(name, ~r/[^a-zA-Z0-9_-]/, "")

  @doc """
  A chip that says a filter is on, with the × that takes it off.

  The same object as `filter_chips/1`, after the fact and outside the panel that
  set it: a count of active filters on a closed button says how many, never
  which, and "which" is what somebody asks when the list is shorter than they
  expected.
  """
  attr :tone, :string, default: "primary", values: ~w(primary info accent warning success)
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(phx-click phx-value-kind phx-value-filter)

  # Never `phx-value-value`. A `<button>` has a `value` property, and the client
  # writes that property over the `value` key after it has read the
  # `phx-value-*` attributes — so the server received an empty string and the
  # chip stayed on the screen. The one kind that dropped was the search, whose
  # value is empty anyway, which is why it looked like a mis-aimed click.

  def filter_pill(assigns) do
    ~H"""
    <button type="button" class={["chip-drop", "tone-#{@tone}"]} {@rest}>
      <span>{@label}</span>
      <.icon name="hero-x-mark" class="size-3.5" />
      <span class="sr-only">{gettext("Remove filter")}</span>
    </button>
    """
  end

  @doc """
  Which box the goods go into — typed, not hunted for in a dropdown.

  Four screens used to render a bare `select` over every box at the location.
  That is fine with six boxes and unusable with a hundred, which is what a real
  warehouse has, on a phone, one-handed, while holding the thing being put away.

  A `datalist` rather than a JavaScript combobox: the browser gives type-ahead,
  keyboard, and a scanner that types a code and presses Enter, for no script at
  all. The field takes a **code** because that is what is written on the box in
  marker pen; `Locations.resolve_box/2` turns it back into a record and creates
  it when the warehouse has a box the system has not met yet.

  The suggestion beneath is the whole reason box assignment is not guesswork —
  see `Locations.suggest_boxes/3`.
  """
  attr :name, :string, required: true
  attr :boxes, :list, required: true
  attr :value, :string, default: nil, doc: "the code to start with"
  attr :list_id, :string, required: true, doc: "shared per location, not per row"
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :class, :any, default: nil

  attr :required, :boolean,
    default: false,
    doc: """
    for the screens where "no box" is not a legitimate answer. Goods recorded
    without one are loose at the location, and loose stock cannot travel: the
    next person to load a mission finds a quantity and nothing to carry it in.
    """

  attr :disabled, :boolean, default: false

  attr :rest, :global

  def box_picker(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <input
        type="text"
        name={@name}
        value={@value}
        list={@list_id}
        placeholder={if(@required, do: gettext("which box"), else: gettext("no box"))}
        required={@required}
        disabled={@disabled}
        autocomplete="off"
        autocapitalize="characters"
        spellcheck="false"
        class="input input-sm input-bordered w-full max-w-40"
        aria-label={@label || gettext("Box")}
        {@rest}
      />
      <p :if={@hint} class="text-xs opacity-70 mt-1">{@hint}</p>
    </div>
    """
  end

  @doc """
  The options behind every `box_picker/1` on the page.

  Rendered once per location rather than once per row: a delivery is forty
  lines and the warehouse's boxes are the same list for all of them.
  """
  attr :id, :string, required: true
  attr :boxes, :list, required: true

  def box_options(assigns) do
    ~H"""
    <datalist id={@id}>
      <option :for={box <- @boxes} value={box.code}></option>
    </datalist>
    """
  end

  @doc """
  The bar above a listing: a search, some filters, the actions that apply to the
  whole set.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def toolbar(assigns) do
    ~H"""
    <!-- Not a `panel` any more. A search box and two filters were sitting in the
         same white sheet, with the same border and radius, as the table of real
         stock underneath — so the page opened with two equal rectangles and
         nothing said which one to read. The toolbar belongs to the page, not to
         the data: it sits on the field, and the sheet below it is the only
         thing with edges. -->
    <div class={["px-1 py-1 flex flex-wrap items-center gap-2", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Nothing here — and why, and what to do about it.

  An operator who reaches an empty screen has either finished the work or taken
  a wrong turn, and a blank page cannot tell them which. The icon is drawn large
  and quiet so the state reads as a resting place rather than as a failure.
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :note, :string, default: nil
  slot :actions

  def empty(assigns) do
    ~H"""
    <div class="py-12 px-6 text-center flex flex-col items-center">
      <div class="rounded-full bg-base-200 p-4 mb-4">
        <.icon name={@icon} class="size-7 text-base-content/40" />
      </div>
      <p class="font-semibold">{@title}</p>
      <p :if={@note} class="text-sm text-base-content/70 mt-1 max-w-md">{@note}</p>
      <div :if={@actions != []} class="mt-4 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  A table of records that survives a phone.

  On a wide screen it is a table with a header that stays put; below `md` each
  record becomes a block: the identity on top, the context beneath it, the
  number that matters on the right — because the alternative is a nine-column
  grid in a horizontal scroller, read one-handed while holding a box.

  No zebra striping: alternating fills say "record set", and rows here are
  positions of real stock. Separation comes from a hairline and from `group`,
  which draws a rule between the columns that answer different questions —
  what it is, where it is, what it is worth.

      <.data_table rows={@rows} sort={@sort} sort_event="sort">
        <:col label={gettext("Product")} key="product" emphasis={:identity} :let={row}>
          {row.product}
        </:col>
        <:col label={gettext("Quantity")} key="quantity" align={:right} emphasis={:primary} :let={row}>
          {row.quantity}
        </:col>
        <:foot>{gettext("45 lot(s)")}</:foot>
      </.data_table>
  """
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "fun building a dom id from a row"
  attr :sort, :map, default: nil, doc: "%{key: key, dir: :asc | :desc}"
  attr :sort_event, :string, default: nil, doc: "event name for a sortable header"
  attr :class, :string, default: nil

  slot :col, required: true do
    attr :label, :string, required: true
    attr :key, :string, doc: "sortable field; omit to make the column fixed"
    attr :align, :atom, values: [:left, :right]
    attr :emphasis, :atom, values: [:identity, :primary, :muted]
    attr :hide_label_on_card, :boolean
    attr :group, :boolean, doc: "starts a new column family; draws a rule to its left"

    attr :width, :string,
      doc: """
      a width class for the header cell, e.g. `"w-[28%]"`. Auto layout gives the
      widest text the most room, which on a stock table means the product name
      takes half the width and the location wraps onto three lines. Setting the
      widths says which columns are allowed to be long.
      """

    attr :field, :atom,
      values: [:inline, :block],
      doc: """
      marks a cell the operator types into. On a card the field *is* the value,
      so :inline keeps it on the right of its label like any other cell and only
      grows it to a thumb-sized target. :block is the escape hatch for a field
      too complex to sit on one line — a search that opens a list, say — and
      stacks it under its label at full width.
      """
  end

  slot :empty, doc: "shown instead of the table when there is nothing"

  slot :foot,
    doc: """
    the totals line. A table that ends without saying what the set adds up to
    makes the reader do arithmetic the system already did.
    """ do
    attr :align, :atom, values: [:left, :right]
    attr :span, :integer
  end

  def data_table(assigns) do
    ~H"""
    <div :if={@rows == []}>
      {render_slot(@empty)}
    </div>

    <table :if={@rows != []} class={["data-table w-full", @class]}>
      <thead>
        <tr>
          <th
            :for={col <- @col}
            scope="col"
            class={
              [
                # Typography, colour and the rule under the row live in
                # `.data-table thead th` — one place, so all twenty-six screens
                # keep the same header. What stays here is what differs per
                # column: which way it reads, whether it starts a family, how
                # wide it is allowed to be.
                "px-3 py-2.5 align-bottom",
                # `th` centres its text by default, which had every header floating
                # over the middle of a column of left-aligned values.
                if(col[:align] == :right, do: "text-right is-numeric", else: "text-left"),
                col[:group] && "group-start",
                col[:width]
              ]
            }
          >
            <button
              :if={@sort_event && col[:key]}
              phx-click={@sort_event}
              phx-value-key={col[:key]}
              class="inline-flex items-center gap-1 hover:text-base-content cursor-pointer"
            >
              {col.label}
              <.icon :if={sorted_by?(@sort, col[:key])} name={sort_icon(@sort)} class="size-3" />
            </button>
            <span :if={is_nil(@sort_event) or is_nil(col[:key])}>{col.label}</span>
          </th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            data-label={col[:emphasis] != :identity and !col[:hide_label_on_card] and col.label}
            class={[
              "px-3 py-2 border-b border-base-200 align-top",
              col[:align] == :right && "text-right tabular-nums is-numeric",
              col[:emphasis] == :identity && "is-identity font-medium",
              col[:emphasis] == :primary && "is-primary font-semibold tabular-nums",
              col[:emphasis] == :muted && "text-sm text-base-content/80",
              col[:field] && "is-field",
              col[:field] == :block && "is-block",
              col[:group] && "group-start"
            ]}
          >
            {render_slot(col, row)}
          </td>
        </tr>
      </tbody>
      <tfoot :if={@foot != []}>
        <tr>
          <td
            :for={cell <- @foot}
            colspan={cell[:span] || 1}
            class={["px-3 py-2 text-sm", cell[:align] == :right && "text-right tabular-nums"]}
          >
            {render_slot(cell)}
          </td>
        </tr>
      </tfoot>
    </table>
    """
  end

  defp sorted_by?(nil, _key), do: false
  defp sorted_by?(_sort, nil), do: false
  defp sorted_by?(sort, key), do: sort.key == key

  defp sort_icon(%{dir: :asc}), do: "hero-arrow-up-micro"
  defp sort_icon(_sort), do: "hero-arrow-down-micro"
end
