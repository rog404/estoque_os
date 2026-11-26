defmodule EstoqueOSWeb.UI do
  @moduledoc """
  The design system: the shapes every screen is built from. `CoreComponents`
  holds the generated pieces; this module holds the operation's decisions.

  **A status has one spelling.** `status/1` owns the vocabulary; a screen names
  the state and never picks a colour, so "presumed" looks the same everywhere.

  **Section colour and status colour never meet at the same scale.** A section
  is a field (band, rail, nav underline); a status is a mark (badge, word, row
  border). Green and red are never spent on navigation.

  **The container is `panel/1`.**
  """

  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  import EstoqueOSWeb.CoreComponents, only: [icon: 1]

  @doc """
  The page header: what this screen is, and what you can do here.

  The hue is inherited from the layout's `data-section`, so the component is
  never told where it is.
  """
  attr :class, :any, default: nil

  attr :back_to, :string,
    default: nil,
    doc: """
    where "up" is from this screen. Rendered above the title, where every
    screen puts it.
    """

  attr :back_label, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <%!-- items-start and a min height keep the title in the same place on every screen. --%>
    <header class={["page-head px-4 sm:px-5 py-4", @class]}>
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3 min-h-[3.5rem]">
        <div class="flex items-stretch gap-3 min-w-0">
          <div class="section-rail w-1 shrink-0" aria-hidden="true" />
          <div class="min-w-0">
            <%!-- `-ml-3` cancels the button's padding so the label lines up with the title. --%>
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

  `flush` is for a panel whose whole body is a table (cells carry their own padding).
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

  Proportional figures on purpose: `tabular-nums` reads loose at this size.
  `tone` tints only numbers somebody should act on; a nothing-to-do count stays
  neutral.
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
    smaller type and less padding, for four or five tiles above the thing
    they describe.
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

  Sits under the field the code was typed into, not at the top of the page. It
  prevents a one-character typo from creating a phantom box. "No" is the loud
  button: the typo is the likely case and a phantom box is found months later.
  """
  attr :code, :string,
    default: nil,
    doc: "the one code that does not exist yet. Use `codes` when a form can name several."

  attr :codes, :list,
    default: nil,
    doc: """
    several codes at once, for screens that submit many lines together; the
    operator must see every new box before any exists.
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

  A closed list on purpose: a new state is decided once, here, not coloured in
  a template.

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
      :migration,
      :bought,
      :unknown_value,
      :pending,
      :stale,
      :deactivated
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

  # Two registers: a state describing the goods is background (`is-quiet`, a dot
  # and a word) so the quantity stays loudest; a state meaning *something is
  # wrong now* keeps the fill, since an alarm on nine rows in ten is no alarm.
  # Controlled (Portaria 344) is a legal class, not a problem: quiet, with an
  # ink dot so it never blends into the amber of an expiry.
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

  # Not for the stock table, which says it in words (a test holds that); this
  # mark is for places where one row is the subject.
  defp status_spec(:presumed),
    do: %{
      class: "is-quiet dot-muted",
      icon: nil,
      label: gettext("presumed")
    }

  defp status_spec(:counted),
    do: %{class: "is-quiet dot-success", icon: nil, label: gettext("counted")}

  # Not an error: a first count that disagrees is more often a miscount than a loss.
  defp status_spec(:recount),
    do: %{class: "badge-warning", icon: nil, label: gettext("count again")}

  defp status_spec(:under_way),
    do: %{class: "is-quiet dot-info", icon: nil, label: gettext("under way")}

  # Loose stock is legitimate but cannot travel: the next job, not an error.
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

  # Quiet, like donation: migrated stock has no cost, but it came from the old
  # control sheet, not from a donor.
  defp status_spec(:migration),
    do: %{class: "is-quiet dot-info", icon: nil, label: gettext("migration")}

  # Quiet, unlike donation: most stock is bought, so the donation is what the eye needs.
  defp status_spec(:bought),
    do: %{class: "is-quiet dot-muted", icon: nil, label: gettext("bought")}

  defp status_spec(:unknown_value),
    do: %{class: "is-quiet dot-muted", icon: nil, label: gettext("value not informed")}

  # Quiet: a place or product taken out of the operation still owns its history.
  defp status_spec(:deactivated),
    do: %{class: "is-quiet dot-muted", icon: nil, label: gettext("deactivated")}

  # Quiet on purpose: most boxes go a while uncounted, so a fill would light up
  # nine rows in ten. It says which box to pick up next.
  defp status_spec(:stale),
    do: %{class: "is-quiet dot-muted", icon: nil, label: gettext("no recent count")}

  defp status_spec(:pending),
    do: %{class: "badge-warning", icon: nil, label: gettext("pending")}

  @doc """
  A box code (AN01, PR03), the identifier the warehouse says aloud, drawn as
  one object everywhere a box appears.

  Loose stock passes `nil` and gets the "no box" treatment: a real, temporary
  state, not a missing value.
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

  Two spans, one displayed, rather than dots positioned over the number:
  absolute positioning breaks in table cells (`display: flex` on phone,
  `table-cell` on laptop).

  **Not a security control.** The real amount is in the markup either way; to
  withhold it, do not render it (see `UserAuth.sees_money?/1`). The preference
  is applied before first paint so amounts never flash.
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
  A checkbox the size of the field beside it, so the whole row is the tap target.
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
  One filter that takes several answers at once, as chips you tick (not a
  native `<select multiple>`, which needs a modifier key).

  The tone is per *kind* of filter; pass the same tone to the group and to
  chips that echo it elsewhere. Chips sit in a grid, not a wrapping row, so a
  ticked chip cannot shift the ones after it under the finger.

  Above `searchable_from` options a box narrows the chips in the browser; a
  server round trip per keystroke would empty the field.
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
      // Narrows the chips in the browser only. A ticked chip never hides.
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
  A chip that says a filter is on, with the × that takes it off; the same
  object as `filter_chips/1`, shown outside the panel that set it.
  """
  attr :tone, :string, default: "primary", values: ~w(primary info accent warning success)
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(phx-click phx-value-kind phx-value-filter)

  # Never `phx-value-value`: the client overwrites a button's `value` property
  # after reading `phx-value-*`, so the server gets an empty string.

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
  Which box the goods go into, typed rather than picked from a dropdown that is
  unusable with a hundred boxes.

  A `datalist`, not a JavaScript combobox: type-ahead, keyboard and scanner
  input come free. The field takes the **code** written on the box;
  `Locations.resolve_box/2` turns it back into a record. See
  `Locations.suggest_boxes/3` for the suggestion beneath.
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
    for screens where "no box" is not legitimate: loose stock cannot travel.
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
  The options behind every `box_picker/1` on the page, rendered once per
  location rather than once per row.
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
    <%!-- Not a `panel`: the toolbar belongs to the page, so the data sheet below is the only thing with edges. --%>
    <div class={["px-1 py-1 flex flex-wrap items-center gap-2", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Nothing here, and why, and what to do about it. The icon is large and quiet so
  the state reads as a resting place, not a failure.
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

  A table on wide screens; below `md` each record becomes a block (identity on
  top, context beneath, the key number on the right) instead of a horizontal
  scroller.

  No zebra striping: rows are positions of real stock. `group` draws a rule
  between columns that answer different questions.

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
      widest text the most room; widths say which columns may be long.
      """

    attr :field, :atom,
      values: [:inline, :block],
      doc: """
      marks a cell the operator types into. :inline keeps it beside its label on
      a card with a thumb-sized target; :block stacks it full width for fields
      too complex for one line.
      """
  end

  slot :empty, doc: "shown instead of the table when there is nothing"

  slot :foot,
    doc: """
    the totals line.
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
                # Shared header styling lives in `.data-table thead th`; only per-column differences here.
                "px-3 py-2.5 align-bottom",
                # `th` centres by default.
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
