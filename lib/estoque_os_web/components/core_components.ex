defmodule EstoqueOSWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: EstoqueOSWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders one flash notice.

  Positioned at the bottom of the screen by the group around it, not the top:
  the bar at the top of every page is the navigation, and a toast landing on it
  covered the menu the operator was reaching for.

  Every flash that carries a message from the server also carries the time it
  has left, drawn as a bar that empties. A notice that vanishes on its own with
  no warning reads as a glitch — you look up and something you half-read is
  gone — and one that never leaves has to be dismissed by hand on a screen used
  one-handed. The bar is what makes disappearing legible.

  Errors get roughly twice as long as confirmations: an error usually asks for
  something ("say which box the goods went into") and has to still be there
  when the eye comes back to it.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"

  attr :dismiss_after, :integer,
    default: nil,
    doc: """
    milliseconds before this notice clears itself, or nil to stay until
    dismissed. Nil is the right answer for the connection notices: "attempting
    to reconnect" is a state, not an announcement, and a state that times out
    is a lie.
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

        <!-- How long is left, and it is the only moving thing on the notice. The
             bar is drawn inside the alert so it takes the alert's own colour,
             which is what keeps a red countdown from reading as a progress
             bar. -->
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
      // Empties the bar over the notice's lifetime, then folds the notice away
      // and clears the flash server-side — gone from the socket rather than
      // only hidden in this tab, because a reconnect used to bring a toast back
      // from the dead.
      //
      // Folding rather than vanishing is the point of the two-step. The notices
      // are stacked, so one that disappears in a single frame makes every
      // notice above it jump down a row; collapsing its height first is what
      // makes them slide.
      export default {
        mounted() {
          const total = parseInt(this.el.dataset.after, 10)
          if (!total) return

          const bar = this.el.querySelector(".flash-countdown")
          if (bar) {
            bar.style.transition = `width ${total}ms linear`
            // Two frames: setting the transition and the target width in the
            // same one is a single style computation, and the bar jumps to
            // empty.
            requestAnimationFrame(() => requestAnimationFrame(() => {
              bar.style.width = "0%"
            }))
          }

          this.timer = setTimeout(() => this.leave(), total)
        },
        leave() {
          this.el.classList.add("is-leaving")
          // Matches the transition in app.css. Clearing the flash before the
          // fold has finished removes the element mid-animation, which is the
          // jump this exists to avoid.
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

  Colour says what the button *does*, not how important it is. Three tones, and
  they are the whole vocabulary:

    * `primary` — the forward action of a screen: search, create, save, go on.
    * `commit` — writes to the ledger. Additive and irreversible: post an
      invoice to stock, send a load, receive a return. Green is the operator
      finishing the thing they came to do.
    * `danger` — removes, deactivates, cancels. Never the resting focus of a
      screen, and never the same colour as the button beside it that commits.

  Omitting the variant gives the soft primary: present, but not the loudest
  thing in the room.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button phx-click="remove" variant="danger">Remove</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
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

    # The caller's class is added to what makes this a button, never swapped for
    # it: passing `class="w-full"` used to silently strip `btn` and leave the
    # control looking like loose text.
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

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
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

  # A password anyone is *setting* rather than typing from memory. Two fields
  # that must match, both of them dots, and the first sign of a typo is being
  # told the confirmation disagrees — with no way to see which of the two is
  # wrong. Rogerio asked for the eye so a new password is not written wrong in
  # the first place.
  #
  # The toggle flips the field's own type; nothing is copied anywhere and
  # nothing is remembered. `autocomplete` still says `new-password`, so a
  # manager keeps working normally.
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
            class={
              [
                @class || "w-full input",
                # Room for the eye, so a long password never runs under it.
                "pr-11",
                @errors != [] && (@error_class || "input-error")
              ]
            }
            {@rest}
          />
          <!-- `tabindex="-1"` on purpose: tabbing out of the password field
               goes to the confirmation, which is what somebody typing a
               password is doing. The eye is for the hand that stopped. -->
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

  # All other inputs text, datetime-local, url, password, etc. are handled here...
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

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Wraps the controls a screen writes from, so they can be shown-but-disabled
  instead of vanishing.

  A hidden button teaches nothing: it cannot be told apart from a feature that
  does not exist, or from a bug. A disabled one with a reason teaches the rule
  and leaves the screen shaped the way the person whose screen it is sees it.

  Two questions, and both are needed. `may` is whether this role writes here at
  all — false removes the markup, because a reader has no business seeing an
  action they will never have. `allowed` is whether *this session* may act now;
  false renders everything and disables it.

  A `<fieldset disabled>` is what does the disabling, and it does it to every
  control underneath including nested forms — one attribute instead of an
  audit of every input. `display: contents` keeps it out of the layout.

  This is not for money. `sees_money?` must keep removing the markup: a price
  that ships to the browser has been given away whether or not it was drawn.
  """
  attr :may, :boolean, required: true, doc: "does this role write here at all"
  attr :allowed, :boolean, required: true, doc: "may this session act right now"
  attr :reason, :string, default: nil, doc: "why not, shown on hover"
  slot :inner_block, required: true

  def write_gate(assigns) do
    ~H"""
    <!-- `min-w-0` and a plain block, not `display: contents`.
         `contents` was the obvious choice and it cost every screen its
         spacing: the page lays its sections out with `space-y-6`, which puts a
         margin on each DOM child after the first — and a margin on a box that
         `contents` has removed from the layout does nothing at all. So on the
         four screens where a form is wrapped in this gate, the form sat welded
         to the table under it. Reported on Caixas, and it was never about
         Caixas.
         A fieldset with no border or padding lays out exactly like the div it
         replaces, and still disables everything inside it in one attribute —
         which is the whole reason it is a fieldset.

         The block margins are left alone deliberately. `m-0` here was the same
         bug wearing a second hat: Tailwind writes `space-y` inside `:where()`,
         which has no specificity, so a plain `m-0` on the child silently wins
         and the gap disappears again. Only the inline margin a fieldset gets
         from the browser is zeroed. -->
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
  states the consequence in the operation's own numbers.

  The ledger is append-only: a mistake is not undone, it is a correcting
  adjustment filed forever with a reason code. That makes the moment before
  the write the only place to be careful, so it gets a real gate rather than a
  toast afterwards.

  Submits the form named by `form`, so the trigger can live outside it.

  `tone` colours both the trigger and the dialog's confirm button, and they must
  agree: a red trigger that opens a dialog whose confirm button is green tells
  the operator, at the last possible moment, that the thing they were warned
  about is safe after all.

  The trigger is the soft fill and the confirm is the solid one. A kit recipe
  has twenty-eight lines, each with a Remove; twenty-eight solid red blocks is a
  screen shouting at somebody who came to read it, and a colour that shouts
  everywhere stops being read anywhere. Loud belongs on the button that actually
  does it, which there is only ever one of.
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
    why the trigger is disabled, on hover. A greyed-out button with nothing to
    hover is the same dead end as a hidden one — the operator still cannot tell
    what would make it work.

    Wins the tooltip over `label` when set, which only matters for icon
    triggers: an icon that cannot be pressed needs to explain that first.
    """

  attr :icon, :string,
    default: nil,
    doc: """
    renders the trigger as a square icon button, with `label` becoming its
    accessible name and its tooltip. For a table where the action repeats on
    every row: the icon is enough to act on, and the dialog still spells the
    whole thing out before anything happens.
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
    *completes* a screen — the write-off that a basket exists to produce, and
    which was being left unpressed because it looked like everything else.

    One per screen and no more. A colour that shouts everywhere stops being
    read anywhere, which is why `:soft` is the default and why a table with
    twenty-eight Remove buttons keeps it.
    """

  attr :rest, :global

  slot :consequence, doc: "what will happen, in numbers"

  def commit_action(assigns) do
    # Not `assign_new`: the attr above declares a default, so the key is always
    # present and `assign_new` never fired. Every caller that left the label to
    # the default got a confirm button with no text on it — the last button
    # before an irreversible write, blank.
    assigns =
      assigns
      |> assign(:confirm_label, assigns.confirm_label || assigns.label)
      |> assign(:tone_class, if(assigns.tone == :danger, do: "btn-error", else: "btn-success"))
      |> assign(:fill_class, if(assigns.emphasis == :loud, do: "btn-lg", else: "btn-soft"))

    ~H"""
    <!-- The tooltip goes on the wrapper, not the button: a disabled button
         swallows pointer events, so its own `title` never appears — which is
         how a "disabled with a reason" turns back into a dead end nobody can
         read. `inline-flex` so it does not change the button's box. -->
    <span title={@disabled && @reason} class="inline-flex">
      <button
        type="button"
        data-confirm-open={@id}
        disabled={@disabled}
        class={["btn", @tone_class, @fill_class, @icon && "btn-square btn-sm"]}
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

      <form method="dialog" class="modal-backdrop">
        <button aria-label={gettext("Close")}>{gettext("Close")}</button>
      </form>
    </dialog>
    """
  end

  @doc """
  The two halves of the spreadsheet round trip: take the stock out, bring a
  count back in.

  Lives here because it is reachable from two places — the stock screen, where
  the operator already is, and a page of its own under Incoming. One definition
  so the two cannot drift apart; the upload itself belongs to each LiveView,
  which is why it arrives as an attribute.
  """
  attr :upload, :any, required: true, doc: "the `@uploads.<name>` struct of the calling view"
  attr :export_path, :string, required: true
  attr :id, :string, default: "import-form"

  def spreadsheet_actions(assigns) do
    ~H"""
    <a href={@export_path} class="btn btn-block">
      <.icon name="hero-arrow-down-tray" class="size-5" />
      {gettext("Export stock")}
    </a>

    <form id={@id} phx-submit="import" phx-change="validate" class="space-y-2">
      <.live_file_input upload={@upload} class="file-input file-input-bordered w-full" />
      <.button class="btn-block" phx-disable-with={gettext("Reading the spreadsheet...")}>
        <.icon name="hero-arrow-up-tray" class="size-5" />
        {gettext("Import count")}
      </.button>
      <p class="text-sm text-base-content/80">
        {gettext("The spreadsheet states what is physically there; only the difference is posted.")}
      </p>
    </form>
    """
  end

  @doc """
  What the last spreadsheet import did, or why it did nothing.
  """
  attr :result, :any, default: nil
  attr :errors, :list, default: []

  def spreadsheet_outcome(assigns) do
    ~H"""
    <div :if={@result} class="alert alert-success mt-4">
      {gettext("%{counted} line(s) read, %{adjusted} position(s) adjusted.",
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

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
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
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

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
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
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
