defmodule EstoqueOSWeb.CoreComponents do
  @moduledoc """
  Core UI building blocks (flash, button, inputs, icon) styled with Tailwind
  and daisyUI.
  """
  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders one flash notice.

  Server flashes carry a countdown bar so a self-dismissing notice does not
  read as a glitch. Errors last about twice as long as confirmations.

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"

  attr :dismiss_after, :integer,
    default: nil,
    doc: """
    milliseconds before this notice clears itself, or nil to stay until
    dismissed (connection notices are a state, not an announcement).
    """

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@dismiss_after && ".FlashCountdown"}
      data-key={@kind}
      data-after={@dismiss_after}
      role="alert"
      class="flash-item"
      {@rest}
    >
      <div class={[
        "alert relative overflow-hidden w-80 sm:w-96 max-w-[calc(100vw-2rem)] text-wrap shadow-lg",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>

        <div
          :if={@dismiss_after}
          class="absolute inset-x-0 bottom-0 h-1 bg-current/15"
          aria-hidden="true"
        >
          <div class="flash-countdown h-full w-full bg-current/50"></div>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".FlashCountdown">
      // Empties the bar, then folds the notice away and clears the flash
      // server-side so a reconnect cannot revive it. Folding first stops the
      // stacked notices above from jumping a row.
      export default {
        mounted() {
          const total = parseInt(this.el.dataset.after, 10)
          if (!total) return

          const bar = this.el.querySelector(".flash-countdown")
          if (bar) {
            bar.style.transition = `width ${total}ms linear`
            // Two frames: in one, transition and target width are a single
            // style computation and the bar jumps to empty.
            requestAnimationFrame(() => requestAnimationFrame(() => {
              bar.style.width = "0%"
            }))
          }

          this.timer = setTimeout(() => this.leave(), total)
        },
        leave() {
          this.el.classList.add("is-leaving")
          // Matches the transition in app.css; clearing earlier cuts the fold short.
          this.exit = setTimeout(() => {
            this.pushEvent("lv:clear-flash", {key: this.el.dataset.key})
          }, 220)
        },
        destroyed() {
          clearTimeout(this.timer)
          clearTimeout(this.exit)
        }
      }
    </script>
    """
  end

  @doc """
  Renders a button with navigation support.

  Colour says what the button *does*, not how important it is:

    * `primary` — the forward action of a screen.
    * `commit` — writes to the ledger (additive, irreversible).
    * `danger` — removes, deactivates, cancels.

  No variant gives the soft primary.

      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  # `type` and `form` are not global attributes, so list them explicitly.
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form target)

  attr :class, :any, default: nil, doc: "added to the button classes, not a replacement for them"
  attr :variant, :string, values: ~w(primary commit danger ghost)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-primary",
      "commit" => "btn-success",
      "danger" => "btn-error",
      "ghost" => "btn-ghost",
      nil => "btn-primary btn-soft"
    }

    # The caller's class is added to `btn`, never swapped for it.
    assigns =
      assign(assigns, :class, ["btn", Map.fetch!(variants, assigns[:variant]), assigns[:class]])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  Takes a `Phoenix.HTML.FormField` or explicit attributes. `type="select"`
  needs `options`; `type="checkbox"` is for booleans. Radio is not supported.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Password with a show/hide eye so a new password is not mistyped. The toggle
  # only flips the field's type; nothing is copied or remembered.
  def input(%{type: "password"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <div class="relative">
          <input
            type="password"
            name={@name}
            id={@id}
            value={Phoenix.HTML.Form.normalize_value("password", @value)}
            class={[
              @class || "w-full input",
              "pr-11",
              @errors != [] && (@error_class || "input-error")
            ]}
            {@rest}
          />
          <%!-- tabindex -1 on purpose: tab goes to the confirmation field. --%>
          <button
            type="button"
            data-password-toggle={@id}
            tabindex="-1"
            class="absolute inset-y-0 right-0 flex w-11 items-center justify-center opacity-50 hover:opacity-90 cursor-pointer"
            aria-controls={@id}
            aria-label={gettext("Show password")}
            title={gettext("Show password")}
            data-show-label={gettext("Show password")}
            data-hide-label={gettext("Hide password")}
          >
            <.icon name="hero-eye" class="size-5 password-shown" />
            <.icon name="hero-eye-slash" class="size-5 password-hidden hidden" />
          </button>
        </div>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Wraps the controls a screen writes from, shown-but-disabled instead of hidden.

  `may` is whether this role writes here at all (false removes the markup).
  `allowed` is whether the controls are drawn usable (false disables them all
  via `<fieldset disabled>`, nested forms included). View-as does not disable;
  the refusal lives in the event hook.

  Not for money: `sees_money?` must keep removing the markup.
  """
  attr :may, :boolean, required: true, doc: "does this role write here at all"
  attr :allowed, :boolean, required: true, doc: "may this session act right now"
  attr :reason, :string, default: nil, doc: "why not, shown on hover"
  slot :inner_block, required: true

  def write_gate(assigns) do
    ~H"""
    <%!-- A plain block, not `display: contents`: the parent's `space-y-6` margins do nothing on a box `contents` removed. Block margins are left alone too: `m-0` would beat the zero-specificity `space-y` rule. Only the fieldset's inline margin is zeroed. --%>
    <fieldset
      :if={@may}
      disabled={not @allowed}
      title={@reason}
      aria-disabled={not @allowed}
      class="min-w-0 border-0 p-0 mx-0"
    >
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  @doc """
  A button that commits something irreversible, behind a confirmation that
  states the consequence in numbers. The ledger is append-only, so the moment
  before the write is the only place to be careful.

  Submits the form named by `form`, so the trigger can live outside it. `tone`
  colours the trigger and the confirm button alike. The trigger is the soft
  fill and the confirm the solid one: loud belongs on the one button that acts.
  """
  attr :id, :string, required: true
  attr :form, :string, required: true, doc: "id of the form this commits"
  attr :label, :string, required: true, doc: "what the trigger says"
  attr :title, :string, required: true, doc: "what the dialog asks"
  attr :confirm_label, :string, default: nil
  attr :disabled, :boolean, default: false

  attr :reason, :string,
    default: nil,
    doc: """
    why the trigger is disabled, on hover. Wins the tooltip over `label`
    when set.
    """

  attr :icon, :string,
    default: nil,
    doc: """
    renders the trigger as a square icon button, with `label` as its
    accessible name and tooltip. For actions repeated on every table row.
    """

  attr :tone, :atom,
    default: :commit,
    values: [:commit, :danger],
    doc: ":commit writes to the ledger; :danger removes or deactivates something"

  attr :emphasis, :atom,
    default: :soft,
    values: [:soft, :loud],
    doc: """
    `:loud` fills the trigger instead of tinting it. For the one action that
    completes a screen; one per screen at most.
    """

  attr :class, :any,
    default: nil,
    doc: """
    added to the trigger's classes, never a replacement for them, and to the
    tooltip wrapper too so a `w-full` trigger actually fills its slot.
    """

  attr :rest, :global

  slot :consequence, doc: "what will happen, in numbers"

  def commit_action(assigns) do
    # Not `assign_new`: the attr default makes the key always present, so it never fires.
    assigns =
      assigns
      |> assign(:confirm_label, assigns.confirm_label || assigns.label)
      |> assign(:tone_class, if(assigns.tone == :danger, do: "btn-error", else: "btn-success"))
      |> assign(:fill_class, if(assigns.emphasis == :loud, do: "btn-lg", else: "btn-soft"))

    ~H"""
    <%!-- Tooltip on the wrapper: a disabled button swallows pointer events, so its own title never shows. --%>
    <span title={@disabled && @reason} class={["inline-flex", @class]}>
      <button
        type="button"
        data-confirm-open={@id}
        disabled={@disabled}
        class={["btn", @tone_class, @fill_class, @icon && "btn-square btn-sm", @class]}
        aria-label={@icon && @label}
        title={(@disabled && @reason) || (@icon && @label)}
        {@rest}
      >
        <.icon :if={@icon} name={@icon} class="size-4" />
        <span :if={is_nil(@icon)}>{@label}</span>
      </button>
    </span>

    <dialog id={@id} class="modal">
      <div class="modal-box">
        <h2 class="text-lg font-semibold">{@title}</h2>

        <div :if={@consequence != []} class="mt-3 space-y-1">
          {render_slot(@consequence)}
        </div>

        <div class="modal-action">
          <button type="button" data-confirm-close class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            form={@form}
            class={["btn", @tone_class]}
            phx-disable-with={gettext("Recording...")}
          >
            {@confirm_label}
          </button>
        </div>
      </div>

      <%!-- A button, not daisyUI's `<form method="dialog">`: this dialog renders inside forms, and the parser drops a nested form (backdrop and click-outside would vanish). `data-confirm-close` already closes it. --%>
      <button
        type="button"
        data-confirm-close
        class="modal-backdrop"
        aria-label={gettext("Close")}
      ></button>
    </dialog>
    """
  end

  @doc """
  The two halves of the spreadsheet round trip: export the stock, import a
  count. Shared by two screens; the upload belongs to each LiveView, so it
  arrives as an attribute.
  """
  attr :upload, :any, required: true, doc: "the `@uploads.<name>` struct of the calling view"
  attr :export_path, :string, required: true
  attr :id, :string, default: "import-form"
  attr :template_path, :string, default: nil, doc: "a blank example sheet to download"

  attr :count_sheet_path, :string,
    default: nil,
    doc: "the count sheet: stock with the balance locked and an empty Contagem column"

  attr :initial_import, :boolean,
    default: false,
    doc: "offer the initial-migration option, which creates items the catalog does not have yet"

  def spreadsheet_actions(assigns) do
    ~H"""
    <a :if={@count_sheet_path} href={@count_sheet_path} class="btn btn-block">
      <.icon name="hero-clipboard-document-check" class="size-5" />
      {gettext("Export count sheet")}
    </a>
    <p :if={@count_sheet_path} class="text-sm text-base-content/70 -mt-1">
      {gettext("Current stock locked, with an empty column to count in the field and import back.")}
    </p>

    <a href={@export_path} class="btn btn-ghost btn-block btn-sm">
      <.icon name="hero-arrow-down-tray" class="size-4" />
      {gettext("Export full stock")}
    </a>

    <a :if={@template_path} href={@template_path} class="btn btn-ghost btn-block btn-sm">
      <.icon name="hero-document-arrow-down" class="size-4" />
      {gettext("Download example spreadsheet")}
    </a>

    <form id={@id} phx-submit="preview" phx-change="validate" class="space-y-2">
      <.live_file_input upload={@upload} class="file-input file-input-bordered w-full" />

      <label :if={@initial_import} class="flex items-center gap-2 text-sm">
        <input type="checkbox" name="create_missing" value="true" class="checkbox checkbox-sm" />
        {gettext("Initial import: create products, places and boxes that do not exist yet")}
      </label>

      <.button class="btn-block" phx-disable-with={gettext("Reading the spreadsheet...")}>
        <.icon name="hero-arrow-up-tray" class="size-5" />
        {gettext("Preview the count")}
      </.button>
      <p class="text-sm text-base-content/80">
        {gettext("The spreadsheet states what is physically there; only the difference is posted.")}
      </p>
    </form>
    """
  end

  @doc """
  Shows what a counted spreadsheet would do before it is posted: how many lines
  import, what blocks them, what is already expired and what will be created.
  Blocked lines can be fixed by creating the product or excluded on the spot, so
  the rest still imports.
  """
  attr :preview, :map, required: true
  attr :excluded, :list, default: []

  def spreadsheet_preview(assigns) do
    ~H"""
    <div class="space-y-4 mt-4">
      <div class="stats stats-horizontal border border-base-300 w-full">
        <div class="stat">
          <div class="stat-title">{gettext("To import")}</div>
          <div class="stat-value text-success">{@preview.total - length(@preview.blocking)}</div>
          <div class="stat-desc">{gettext("line(s)")}</div>
        </div>
        <div :if={@preview.blocking != []} class="stat">
          <div class="stat-title">{gettext("Blocked")}</div>
          <div class="stat-value text-error">{length(@preview.blocking)}</div>
          <div class="stat-desc">{gettext("fix or exclude them")}</div>
        </div>
        <div :if={Map.get(@preview, :not_counted, 0) > 0} class="stat">
          <div class="stat-title">{gettext("Not counted")}</div>
          <div class="stat-value">{@preview.not_counted}</div>
          <div class="stat-desc">{gettext("left untouched")}</div>
        </div>
      </div>

      <div :if={@preview.blocking != []} class="rounded-box border border-error/40 p-4 space-y-2">
        <p class="font-semibold text-error">{gettext("These lines block the import:")}</p>
        <div :for={row <- @preview.blocking} class="flex items-start justify-between gap-2 text-sm">
          <span>
            {gettext("line %{line}: %{message}",
              line: row.line,
              message: preview_issue_messages(row)
            )}
          </span>
          <div class="flex shrink-0 gap-1">
            <.button
              :if={unknown_product(row)}
              phx-click="create_product"
              phx-value-line={row.line}
              class="btn-xs"
            >
              {gettext("Create product")}
            </.button>
            <.button
              phx-click="exclude"
              phx-value-line={row.line}
              class="btn-xs btn-outline btn-error"
            >
              {gettext("Exclude")}
            </.button>
          </div>
        </div>
      </div>

      <details
        :if={@excluded != []}
        class="collapse collapse-arrow border border-base-300 rounded-box"
      >
        <summary class="collapse-title font-medium flex items-center gap-2">
          <.icon name="hero-no-symbol" class="size-5" />
          {gettext("Excluded (%{count})", count: length(@excluded))}
        </summary>
        <div class="collapse-content space-y-1">
          <div :for={row <- @excluded} class="flex items-center justify-between gap-2 text-sm">
            <span>{gettext("line %{line}: %{product}",
              line: row.line,
              product: row.product || gettext("box %{code}", code: row.box)
            )}</span>
            <.button phx-click="restore" phx-value-line={row.line} class="btn-xs btn-ghost">
              {gettext("Restore")}
            </.button>
          </div>
        </div>
      </details>

      <.preview_group
        :if={@preview.products_to_create != []}
        tone="warning"
        icon="hero-plus-circle"
        title={gettext("Products to create (%{count})", count: length(@preview.products_to_create))}
        note={gettext("not in the catalog yet — created when you confirm")}
        items={@preview.products_to_create}
      />

      <.preview_group
        :if={@preview.expired != []}
        tone="warning"
        icon="hero-exclamation-triangle"
        title={gettext("Already expired (%{count})", count: length(@preview.expired))}
        note={gettext("imported anyway; write them off by adjustment to record the disposal")}
        items={Enum.map(@preview.expired, &expired_label/1)}
      />

      <.preview_group
        :if={@preview.named_only_boxes != []}
        tone="info"
        icon="hero-archive-box"
        title={gettext("Boxes with a name only (%{count})", count: length(@preview.named_only_boxes))}
        note={gettext("registered empty, with no stock line")}
        items={@preview.named_only_boxes}
      />

      <.preview_group
        :if={@preview.locations_to_create != []}
        tone="info"
        icon="hero-map-pin"
        title={gettext("New places (%{count})", count: length(@preview.locations_to_create))}
        note={gettext("created when you confirm")}
        items={@preview.locations_to_create}
      />

      <.preview_group
        :if={@preview.boxes_to_create != []}
        tone="info"
        icon="hero-cube"
        title={gettext("New boxes (%{count})", count: length(@preview.boxes_to_create))}
        note={gettext("created when you confirm")}
        items={@preview.boxes_to_create}
      />

      <div class="flex items-center gap-2">
        <.button
          variant="primary"
          class="btn-block"
          phx-click="confirm"
          disabled={@preview.blocking != []}
          phx-disable-with={gettext("Importing...")}
        >
          <.icon name="hero-check" class="size-5" />
          {gettext("Confirm and import")}
        </.button>
        <.button phx-click="start_over" class="btn-ghost">
          {gettext("Start over")}
        </.button>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :note, :string, default: nil
  attr :icon, :string, required: true
  attr :tone, :string, default: "info"
  attr :items, :list, required: true

  defp preview_group(assigns) do
    ~H"""
    <details class="collapse collapse-arrow border border-base-300 rounded-box">
      <summary class="collapse-title font-medium flex items-center gap-2">
        <.icon name={@icon} class={["size-5", @tone == "warning" && "text-warning"]} />
        {@title}
      </summary>
      <div class="collapse-content">
        <p :if={@note} class="text-sm text-base-content/70 mb-2">{@note}</p>
        <ul class="list-disc list-inside text-sm space-y-0.5">
          <li :for={item <- @items}>{item}</li>
        </ul>
      </div>
    </details>
    """
  end

  defp expired_label(row) do
    "#{row.product} — #{Calendar.strftime(row.expires_on, "%d/%m/%Y")}"
  end

  defp unknown_product(row) do
    Enum.any?(row.issues, &match?({:product_unknown, _name}, &1))
  end

  defp preview_issue_messages(row) do
    row.issues
    |> Enum.map(&preview_issue_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp preview_issue_message(:product_missing), do: gettext("the product name is missing")
  defp preview_issue_message(:location_missing), do: gettext("the location is missing")
  defp preview_issue_message(:quantity_missing), do: gettext("the quantity is missing")
  defp preview_issue_message(:quantity_negative), do: gettext("the quantity is negative")

  defp preview_issue_message({:product_unknown, name}),
    do: gettext("product \"%{name}\" is not in the catalog", name: name)

  defp preview_issue_message({:location_unknown, name}),
    do: gettext("location \"%{name}\" does not exist", name: name)

  defp preview_issue_message({:box_elsewhere, location}),
    do: gettext("the box is at %{location}", location: location)

  defp preview_issue_message(_issue), do: nil

  attr :result, :any, default: nil
  attr :errors, :list, default: []

  def spreadsheet_outcome(assigns) do
    ~H"""
    <div :if={@result} class="alert alert-success mt-4">
      {gettext("%{counted} line(s) read, %{adjusted} lot(s) adjusted.",
        counted: @result.counted,
        adjusted: @result.adjusted
      )}
    </div>

    <div :if={@errors != []} class="alert alert-error flex-col items-start gap-2 mt-4">
      <p class="font-semibold">{gettext("Nothing was imported. Fix these lines:")}</p>
      <ul class="list-disc list-inside text-sm">
        <li :for={error <- @errors}>
          {gettext("line %{line}: %{message}", line: error.line, message: error.message)}
        </li>
      </ul>
    </div>
    """
  end

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com); `-solid` and `-mini` suffixes
  pick other styles. Bundled into app.css by `assets/vendor/heroicons.js`.

      <.icon name="hero-x-mark" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # Messages are generated dynamically, so call Gettext with the backend
    # explicitly; translations live in errors.po.
    if count = opts[:count] do
      Gettext.dngettext(EstoqueOSWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EstoqueOSWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
