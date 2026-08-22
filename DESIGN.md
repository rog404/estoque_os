# DESIGN.md — Estoque Operação Sorriso

The visual system, recorded from what is built rather than from what was
intended. `PRODUCT.md` owns product truth; this file owns durable visual
decisions. When the two disagree, PRODUCT.md wins.

**Mode: Operate.** Every screen here exists so somebody completes a task —
receiving a delivery, counting a box, sending a load, answering an auditor.
Expression never obscures the task, the state, or a familiar affordance. Brand
lives in precise details, not in decoration.

## 0. The provisional-identity rule

Operação Sorriso has an official visual identity and **the asset files are not
available yet.** Nothing here may be presented as their brand.

Everything brand-bearing is deliberately confined so that swapping in the real
identity is a small, findable change:

| What | Where | How it is replaced |
|---|---|---|
| Palette | the two `daisyui-theme` blocks in `assets/css/app.css` | edit the oklch values in place |
| Typeface | the `@font-face` blocks and `--font-sans` in `app.css` | drop in the real woff2, change one variable |
| Mark | `Layouts.mark/1` | replace the inline SVG with an `<img>`, delete the function body |

The mark is a carton drawn in one colour, because a box is the noun the whole
system turns on: everything here is something in a box, going somewhere, coming
back. It is a placeholder that looks designed, not a logo.

## 1. Foundations

### Type

**Archivo**, self-hosted variable, weight 400–700 and width 62–125%. One family
carries every role. Headings take the *width* axis rather than a second family —
`font-stretch: 108%` with `-0.015em` tracking — so they read as decided instead
of as the default sans.

Base size is **17px**, not the 16px web default: this is read at arm's length,
in a warehouse, often on a phone.

Figures are **tabular** in tables, in numeric inputs, and anywhere a column of
quantities must line up. They are deliberately *not* tabular in `stat/1`, where
zero-width digits read loose at 3xl.

`.eyebrow` is the small-caps label that names a group of things: 0.6875rem, 600,
0.08em tracking.

### Colour

Light is the default — the use scene is a bright office and a daylit warehouse.
Dark exists for the badly lit storage rooms of a mission.

Colour is spent in **three channels that never meet at the same scale**, which is
the rule that keeps an Operate surface readable:

| Channel | Scale | Says |
|---|---|---|
| **Section** | a line — rail, header rule, nav underline | where you are |
| **Status** | a mark — badge, one word, a row's border | what this thing is |
| **Action** | a filled control | what will happen if you press it |

Green and red belong to the ledger's own answers and to actions. They are never
spent on navigation.

### Section identity

The menu is grouped the way the operation is sequenced, and each group carries a
hue. On a phone in a storage room the colour arrives before the words do.

| Section | Hue | Menu |
|---|---|---|
| Incoming | 200, cyan | Entradas |
| Operation | 295, violet | Operação |
| Stock | 252, blue (the default) | Estoque |
| Reports | 75, gold | Relatórios |

Reports takes gold rather than a second blue. Nothing takes green or red.

**Only the hue is a variable.** Lightness and chroma are written at the point of
use, because a custom property containing `var()` is substituted *where it is
declared*, not where it is read — deriving `--section-tint` on `:root` froze
every section at the root's hue and the whole app came out blue. The scale is
five lines:

```
rail   56% / 0.15    the spine beside a page title
ink    44% / 0.13    the section's own name
edge   89% / 0.045   the rule under the header
mark   74% / 0.15    read against the near-black bar
```

The section is derived from the menu by longest-prefix match
(`Layouts.active_section/1`), never declared per screen: the nav is already the
statement of how this system is divided, and a screen free to name its own
section is a screen free to disagree with the menu it sits under. The key is a
stable English string, so a translation can never repaint the app.

### Surfaces

Three planes. The app used to have one — panels were `base-100` on a `base-100`
ground separated by a hairline — and that is where the flatness came from.

```
app bar    near-black, sticky, constant across sections
page head  a rail and a hairline in the section's colour, no fill
ground     base-200
panel      base-100, 1px base-300, no shadow
```

**Flat, and deliberately so.** Panels carry no shadow: three planes already
separate ground from panel from bar, and a shadow simulates a depth that says
nothing. The page header was a tinted band and is now a line — the section is
still named by colour on the rail, the rule and the nav underline, but a field
of colour at the top of every screen competes with the data underneath it.
Radii are tight (`box` 0.375rem, `field` 0.25rem): soft corners read as
friendly, and this is a tool.

daisyUI paints the root with `--root-bg`, and a painted root stops the body's
background from propagating to the canvas. `--root-bg` is set to `base-200`
rather than fought with a selector.

### Control sizing

`--size-field` and `--size-selector` are both **0.25rem**, so a field is 2.5rem
tall and a checkbox is 1.5rem. They were 0.21875rem, which made a 22px checkbox
sit beside a 37px input — and four screens shrank it further with `checkbox-sm`.
These are sized for a gloved hand in a warehouse, not a mouse in an office.

## 2. Components

`CoreComponents` holds what Phoenix generates — flash, form inputs, `icon/1`,
`button/1`, `commit_action/1`. `EstoqueOSWeb.UI` holds what this operation
decided.

| Component | Use |
|---|---|
| `header/1` | the page band: title, subtitle, actions, section rail. One per screen. |
| `panel/1` | **the** container. Title, note, actions, `flush` for tables. No icon: the title already says what it is. |
| `stat/1` | one number, optionally a link, optionally toned. |
| `status/1` | the closed status vocabulary. |
| `check/1` | a checkbox the size of the field beside it. |
| `toolbar/1` | search + filters above a listing. |
| `empty/1` | nothing here — and why, and what to do about it. |
| `data_table/1` | the record table, with `:foot` totals and `:empty`. |
| `amount/1` | an amount that follows the eye in the bar. |

`.panel`, `.panel-head`, `.panel-body` and `.field-row` also exist as plain CSS
classes, so a `<form>` that needs to be a panel wears the same clothes as the
`<section>` that is one.

### The status vocabulary

A screen **names a state**; it never picks a colour. The list is deliberately
closed — a state that is not here is a state nobody has agreed on yet, and
adding one is a decision made once, in `UI.status_spec/1`.

| Kind | Colour | Why |
|---|---|---|
| `:expired` | error | |
| `:expiring` | warning | |
| `:controlled` | **neutral, solid** | A Portaria 344 substance is not a problem and not a warning — it is a legal class that changes who may touch the box. Seven screens had picked `badge-error` for it independently. |
| `:presumed` | outline | Never on the stock table — see below. |
| `:counted` | success | |
| `:in_kit`, `:in_transit`, `:under_way` | info | Movement, not trouble. |
| `:incomplete`, `:below_minimum`, `:needs_review`, `:unboxed`, `:not_linked`, `:pending` | warning | Somebody's next job. |
| `:complete` | success | |
| `:donation` | accent | The warm accent, spent only where the work is humane. |
| `:unknown_value` | ghost | |

**No icons on badges.** At 12px, repeated dozens of times down a table, they
are texture rather than information. The word carries the meaning and the
accessibility; status is never conveyed by colour alone because there is always
a word.

**"Presumed" is words on the stock table, not a badge.** It was a 10px ghost
badge once and became the least visible thing on a screen whose entire claim is
that it separates counted from inherited. `stock_filter_test.exs` holds this.

### The action vocabulary

Colour says what the button *does*, not how important it is.

| Variant | Colour | Use |
|---|---|---|
| `primary` | primary | the forward action: search, create, save, go on |
| `commit` | success | writes to the ledger: post an invoice, send a load, receive a return |
| `danger` | error | removes, deactivates, cancels |
| `ghost` | none | dismiss, cancel a dialog |
| *(omitted)* | soft primary | present, not the loudest thing in the room |

`commit_action/1` colours its trigger **and** its dialog's confirm from one
`tone`: a red trigger opening a green confirm tells the operator, at the last
possible moment, that the thing they were warned about is safe after all.

**The trigger is soft, the confirm is solid.** A kit recipe has twenty-eight
lines each with a Remove; twenty-eight solid red blocks is a screen shouting at
somebody who came to read it. Loud belongs on the button that actually does it,
and there is only ever one of those.

Where an action repeats on every row, `commit_action/1` takes an `icon` and
becomes a square icon button — the words survive as the accessible name and the
tooltip, and the dialog still spells the whole thing out.

**A link goes to another page. A button does something to this one.** That is
the entire rule for whether a control is `<.link navigate={...}>` or a
`.btn`-family `<button>`, and it is the only rule an operator needs to answer
"is this clickable, and what happens if I do" without reading the word first.
`invoice_live/show.ex` broke it once: reopening a resolved line for editing —
`phx-click="edit"`, nothing about it leaves the page — was styled `link
link-hover`, identical to the genuine navigation links two rows below it
("Ver estoque", "Ver a nota"). It is a `.btn.btn-ghost.btn-xs` now, matching the
X that clears a wrong catalog match beside it. A plain link that fires a
`phx-click` and stays on the page is always this bug, not a style choice —
audit new ones by checking what the control actually does, not by copying the
nearest existing class.

Size follows where the control sits, and this is the whole rule — not a table
to look up per screen:

| Where | Size |
|---|---|
| A page's own actions, in the header | default (unsized `.btn`) |
| An action scoped to one card or table row | `btn-sm` |
| An icon-only control repeated down a list | `btn-ghost btn-square btn-sm` |

The icon-only row control was `btn-xs`, and `commit_action/1` — the one
component that renders exactly that control — had always drawn it `btn-square
btn-sm`. Two answers to one question, and the smaller one was a 24px target on
a screen §5 promises 2.5rem on. It is `btn-sm` everywhere now, and the doc
follows the component rather than the other way round.

Classes are written in the order `btn` → colour → shape → size, so the same
control greps the same way on every screen. `btn btn-sm btn-ghost btn-square`
and `btn btn-ghost btn-square btn-sm` render identically and read as two
different patterns.

### The button is the component, and it never takes a colour in `class`

`button/1` *adds* the caller's class to what makes a button, so a colour passed
in `class` does not replace the variant — it joins it. Four controls on the
login confirmation screen were `<.button class="btn btn-primary w-full">`, which
shipped `btn-primary btn-soft` **and** `btn-primary`: the solid fill the author
wanted, fighting the soft one the omitted variant supplies, and which of the two
won depended on stylesheet order. Colour goes in `variant`. `class` is for
layout — `w-full`, `btn-block`, a margin, a size.

`type` and `form` are on `button/1`'s `:global` include list because they are
not global HTML attributes and every `<.button type="button">` in the app was
compiling with a warning. A warning on the correct spelling is an argument for
the wrong one, and hand-written `class="btn ..."` is what people wrote instead.

### The resting tier had three spellings

`btn-outline` and a bare colourless `.btn` were both in use, alongside the
documented soft primary, for the same job: a control that is present without
being the loudest thing on the screen. Three spellings of one tier is how a
screen ends up with an outline button beside a soft one beside a base-200 one,
all meaning "secondary" — and the bare `.btn` was the worst of them, because
`base-200` on the `base-200` ground is a control that does not read as a
control. Both are gone: twenty-two of them across fifteen screens are `<.button>`
with no variant.

The one exception is a `<summary>` that opens a dropdown — the stock screen's
filter trigger. It cannot be a `<button>` element, so it keeps the plain
`.btn` classes, and it is a *toggle* rather than an action: it does not belong
to the action vocabulary at all.

## 3. The data table

One DOM, two shapes. A desktop table and a mobile card list written as separate
markup would duplicate every id inside a cell, which is invalid HTML and breaks
LiveView — so the table **collapses into blocks with CSS** below `md`: identity
on top, context beneath, the number that matters on the right.

- **No zebra striping.** Alternating fills say "record set"; these rows are
  positions of real stock.
- **The header sticks** under the app bar. Forty-five rows scrolled past a
  header that left with them.
- **Money never wraps.** A value broken across two lines reads as two numbers.
- **`group`** draws a rule between column families — what it is, where it is,
  what it is worth — rather than a border around every cell.
- **`width`** sets explicit column widths. Auto layout gives the longest text the
  most room, which on a stock table means the product name takes half the width
  and the location wraps onto three lines.
- **`<th>` is left-aligned.** Its default is centre, which had every header
  floating over the middle of a column of left-aligned values.
- **`:foot`** carries totals. A table that ends without saying what the set adds
  up to makes the reader do arithmetic the system already did. Totals skip nils
  rather than treating them as zero — a donation with no informed value is
  unknown, and adding it in as nothing understates the page.
- **`:empty`** carries an `empty/1`, never a bare sentence. An operator who
  reaches a blank screen has either finished the work or taken a wrong turn, and
  a blank page cannot tell them which.

### The header is a fixed shape

The title lands at the same y on all twenty-six screens, and the band is the
same height whether or not the screen has a subtitle. It used to align to the
bottom of its row, so a title sank whenever the screen had no subtitle or a tall
button beside it — and a heading that moves between pages reads as twenty-six
layouts rather than one.

### Hidden amounts

The eye in the bar swaps which of two spans is shown: the amount, or `R$ ••••`.
Two spans rather than dots positioned over the number, because a cell is
`display: flex` on a phone and `table-cell` on a laptop and absolute positioning
breaks in one of them. Never a blur — a blur still says "a number is here, lean
closer".

**It starts hidden, always.** A default that reveals has already shown the
figures to whoever was standing there; showing them is the deliberate act. The
choice lives in `sessionStorage`, so revealing lasts while you work and a new
browser starts covered — `localStorage` would turn one click into a permanent
decision, which is the default this replaces.

Applied before first paint, so the amounts never flash on and then vanish.

**Not a security control.** The real amount is in the markup either way. What
keeps a price from a partner outside the ONG is not rendering it at all; see
`UserAuth.sees_money?/1`.

### Navigation names places, not steps

The menu lists where you can *be*. Importing an invoice is something you do once
you are already in invoices, so it lives on that screen — in its header and in
its empty state — and not in the bar. A filter's "no filter" option names its
dimension (`Todos os locais`) rather than reading `todos` or, worse, sitting
blank: an empty option reads as a control that failed to load, and a closed
select should say what it is doing.

### Going back is one control, and it is `header/1`'s

Three different answers to "how do I get back to the list" had shipped at
once: `header/1`'s own `back_to`/`back_label` (two screens), a plain text
link sitting alone at the foot of the page (five screens — an invoice, an
audit count, a receipt, the spreadsheet importer), and a `.btn.btn-ghost`
parked in the header's *actions* slot on the right instead of the back slot on
the left (two more, each phrased differently — "Back to stock", "All
missions"). Three styles and two positions for the same question is why it
stopped reading as a pattern.

There is now one: every screen that is one specific record drilled into from
exactly one list carries `back_to`/`back_label` on its `<.header>`, top-left,
next to the section rail. It renders as a `.btn.btn-ghost.btn-sm` — a real
button with a hover box, not a quiet inline link — because it is the one
control every screen shares, and it had been the exception to "a link goes
somewhere, a button looks like a button." The label is always the
destination's own name (`gettext("Stock")`, `gettext("Invoices")`), the same
string the nav already uses for that place, never a "back to..." sentence —
the two-screen version that had already shipped this way turned out to be the
one worth keeping.

A screen that is itself a place in the nav bar — `/audit`, `/stock/spreadsheet`,
`/entry`, `/conferences` — does not get one: it is not drilled into from a
list, it *is* the list, and a back button on a nav destination answers a
question nobody standing there is asking. A "back to X" link stacked directly
below a page that already carries `back_to` for the same X was a plain
duplicate and came out. A link to a *different* related record — the invoice
a receipt was opened from, the box a count belongs to, the "cancel" beside an
import form's submit button — is not this pattern and stays exactly where it
was: it names a different place, or it pairs with a specific action rather
than answering "where did I come from."

## 4. Forms

`.field-row` is the row where some controls carry a label and some do not.
daisyUI's `.fieldset` puts 4.25px of padding below its field, so `items-end`
aligned a bare button to the bottom of the *label's box* rather than the input
inside it — every button in the app sat five pixels lower than the fields beside
it. Measured, then fixed.

`check/1` gives a checkbox the input's exact height, border and radius, so in a
form grid a checkbox row and a text field are the same object — and on a phone
the whole row is the tap target rather than a 22px square somebody has to aim at
while holding a box.

## 5. Accessibility

Mobile layout is a functional requirement: this is used on phones inside
warehouses and hospital storage rooms. No formal standard has been agreed with
the ONG yet — an open decision. Honored today: labelled controls, keyboard-
reachable actions, status conveyed by **text and icon, never by colour alone**
(every `status/1` carries a word, and most carry a shape), icon-only buttons
carrying `aria-label`, and a 2.5rem minimum control height.

## 6. What is not decided

- The real brand assets, and everything in §0 that waits on them.
- Whether the accent should keep its donation-only discipline once the ONG sees
  it in use.
- An accessibility standard to test against.
