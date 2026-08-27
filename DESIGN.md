---
name: Estoque Operação Sorriso
description: A stock ledger drawn as a Miura sheet — one warm surface, scored with linked creases, that leaves the warehouse folded and comes back partly open.
colors:
  sheet-white: "oklch(99.2% 0.0025 85)"
  sheet-ground: "oklch(96.8% 0.005 85)"
  mountain-grey: "oklch(87% 0.009 82)"
  sheet-ink: "oklch(19% 0.006 80)"
  valley-blue: "oklch(46% 0.115 248)"
  valley-wash: "oklch(93% 0.028 245)"
  valley-line: "oklch(62% 0.09 245)"
  mountain-fill: "oklch(93% 0.008 82)"
  mountain-line: "oklch(66% 0.012 82)"
  packet-face: "oklch(21% 0.008 80)"
  accent-indigo: "oklch(38% 0.13 268)"
  graphite-bar: "oklch(24% 0.006 80)"
  graphite-ink: "oklch(97% 0.004 85)"
  ledger-info: "oklch(52% 0.115 245)"
  ledger-success: "oklch(50% 0.115 158)"
  ledger-warning: "oklch(63% 0.165 56)"
  ledger-error: "oklch(52% 0.2 27)"
typography:
  display:
    fontFamily: "Archivo, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.5rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "0.004em"
    fontVariation: "wdth 112"
  headline:
    fontFamily: "Archivo, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-0.015em"
    fontVariation: "wdth 92"
  title:
    fontFamily: "Archivo, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.75rem"
    fontWeight: 600
    lineHeight: 1.05
    letterSpacing: "-0.015em"
    fontVariation: "wdth 100"
    fontFeature: "tnum 1"
  body:
    fontFamily: "Archivo, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: "Chivo Mono, ui-monospace, SFMono-Regular, monospace"
    fontSize: "0.625rem"
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: "0.11em"
  code:
    fontFamily: "Chivo Mono, ui-monospace, SFMono-Regular, monospace"
    fontSize: "0.8125rem"
    fontWeight: 500
    lineHeight: 1.35
    letterSpacing: "-0.01em"
    fontFeature: "tnum 1"
rounded:
  selector: "0.1875rem"
  field: "0.25rem"
  box: "0.375rem"
  pill: "999px"
spacing:
  hairline: "1px"
  tight: "0.375rem"
  cell: "0.75rem"
  panel: "1rem"
  bar: "3.5rem"
components:
  button-resting:
    backgroundColor: "{colors.valley-blue}"
    textColor: "{colors.valley-blue}"
    rounded: "{rounded.field}"
    height: "2.1875rem"
  button-primary:
    backgroundColor: "{colors.valley-blue}"
    textColor: "{colors.sheet-white}"
    rounded: "{rounded.field}"
    height: "2.1875rem"
  button-danger:
    backgroundColor: "{colors.ledger-error}"
    textColor: "{colors.sheet-white}"
    rounded: "{rounded.field}"
    height: "2.1875rem"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.field}"
    height: "2.1875rem"
  button-packet:
    backgroundColor: "{colors.packet-face}"
    textColor: "{colors.sheet-ink}"
    rounded: "0"
    padding: "0 1.5rem 0 1rem"
    height: "2.1875rem"
  panel:
    backgroundColor: "{colors.sheet-white}"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.box}"
    padding: "{spacing.panel}"
  field-cell:
    backgroundColor: "transparent"
    textColor: "{colors.sheet-ink}"
    rounded: "0"
    padding: "0.875rem 1rem 1rem"
  input:
    backgroundColor: "{colors.sheet-white}"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.field}"
    height: "2.1875rem"
  input-focus:
    backgroundColor: "{colors.valley-wash}"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.field}"
    height: "2.1875rem"
  badge-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.pill}"
    padding: "0"
  badge-alarm:
    backgroundColor: "{colors.ledger-error}"
    textColor: "{colors.sheet-white}"
    rounded: "{rounded.pill}"
    padding: "0 0.5rem"
  chip-check:
    backgroundColor: "{colors.sheet-white}"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.pill}"
    padding: "0.3rem 0.625rem"
    typography: "{typography.body}"
  box-code:
    backgroundColor: "{colors.sheet-white}"
    textColor: "{colors.sheet-ink}"
    rounded: "{rounded.selector}"
    padding: "0.0625rem 0.375rem"
    typography: "{typography.code}"
  quick-action:
    backgroundColor: "{colors.sheet-white}"
    textColor: "{colors.sheet-ink}"
    rounded: "0"
    padding: "0.75rem 0.875rem"
---

# Design System: Estoque Operação Sorriso

The visual system, recorded from what is built rather than from what was
intended. `PRODUCT.md` owns product truth; this file owns durable visual
decisions. When the two disagree, PRODUCT.md wins.

## Overview

**Creative North Star: "The Miura Sheet"**

A stock ledger is one surface, scored with linked creases, that leaves the
warehouse folded and comes back partly open. That is not a mood; it is the
product. A Miura sheet has exactly two kinds of line — the mountain, raised
toward you, and the valley, pressed away — and a stock ledger has exactly two
kinds of movement, goods arriving and goods leaving. Every crease chart ever
printed draws the two as two strokes so a folder can read the sheet in bad
light without turning it over. This app had the same binary and drew it as four
badge hues. Now it draws the stroke as well.

**Mode: Operate.** Every screen exists so somebody completes a task —
receiving a delivery, counting a box, sending a load, answering an auditor.
Expression never obscures the task, the state, or a familiar affordance. The
world is spent on materials (warm paper, a hairline crease, one stamped seal), not
on ornament laid over the data.

This world replaced a cool blue-grey admin surface, and the replacement is a
set of refusals with names. The KPI-card row is gone — four rounded boxes with
drop shadows and hover lifts, three of which were never clickable, promising an
affordance that did not exist and saying "four objects" about one reading. It
is a ruled identification block now. Floating shadowed tiles are gone. The navy
bar is graphite, because the bar is the one plane that is not paper and a
saturated blue parked at the top of every screen reads as a second brand
colour. Status keeps its closed colour vocabulary and always carries a word.

**Key Characteristics:**

- Warm sheet-white ground; nothing on the page is a cool screen colour that
  wandered in.
- Mountain-grey hairlines instead of borders and shadows: the sheet's own fold.
- Valley-blue wash for focus and for what arrived; solid ink for the one
  irreversible act per screen.
- One typeface on its width axis for prose, one mono for every crease id.
- Panels are flat sheets, no turned corner; page headers carry 60°
  scoring.
- Flat by construction. Three planes, no elevation shadows anywhere.

### The provisional-identity rule

Operação Sorriso has an official visual identity and **the asset files are not
available yet.** Nothing here may be presented as their brand. Everything
brand-bearing is deliberately confined so that swapping in the real identity is
a small, findable change:

| What | Where | How it is replaced |
|---|---|---|
| Palette | the two `daisyui-theme` blocks in `assets/css/app.css` | edit the oklch values in place |
| Typefaces | the four `@font-face` blocks and `--font-sans` / `--font-mono` in `app.css` | drop in the real woff2 files, change two variables |
| Mark | `Layouts.mark/1` | replace the inline SVG with an `<img>`, delete the function body |
| Packet face | `--packet-face` / `--packet-ink` in `app.css` | two declarations; the commit control reads them |

The mark is the Miura crease pattern itself — three zig-zag rows and the
verticals that link them — drawn in ink on paper. It is the actual pattern, not a
suggestion of one, because the two line families are why a sheet deploys in one
pull, and a stock that leaves whole and returns in pieces is the same geometry.
It is a placeholder that looks designed, not a logo.

**The No-Gold Rule.** There is no gold in this system, and its removal is a
decision rather than an omission. Foil was the packet's face in the crease
chart, and on a surgical charity's stock screen it read as luxury — the one
association this operation has no use for. The world lost nothing: a Miura
sheet is paper, ink and two kinds of crease, and the fold is what carries it.
Gold was the only borrowed note. The chamfer was always the part doing the
work.

## Colors

Warm paper, one cool accent taken from the crease chart, and one metallic —
held to a single act.

### Primary

- **Valley Blue** (`{colors.valley-blue}`): the crease pressed away from you.
  It is the forward action (search, create, save, go on), the active nav
  marker, and — as its pale wash `{colors.valley-wash}` with the
  `{colors.valley-line}` edge — every focused field and every selected or
  hovered cell. Focus was a 2px ring floating outside the control; it is the
  control sitting in its crease now, which is easier to find because a filled
  field is visible in peripheral vision and a ring is not.

### Secondary

- **Mountain Grey** (`{colors.mountain-grey}`): the crease seen from the raised
  side, and every hairline in the app — panel edge, table rule, field-block
  rule, the divider inside the quick row. It is not a border colour; it is the
  sheet's own fold, which is why it is used at 1px and never at 2px.
  `{colors.mountain-fill}` and `{colors.mountain-line}` are its filled and
  drawn forms, used for the disabled packet and the leaving stroke.

### Tertiary

- **Accent Indigo** (`{colors.accent-indigo}`): the valley taken to its
  darkest, so the accent stays inside the world's own family and still cannot
  be mistaken for the blue that means "go on" or the amber that means "soon".
  Spent only where the work is humane: a donation.


### Neutral

- **Sheet White** (`{colors.sheet-white}`): panels, fields, table rows. Warm,
  because paper is warm.
- **Sheet Ground** (`{colors.sheet-ground}`): the table the sheet lies on. Set
  on `body` and on daisyUI's `--root-bg`, because a painted root stops the
  body's background from reaching the canvas and the ground ended where the
  content ended.
- **Sheet Ink** (`{colors.sheet-ink}`): all body text, and the focus outline on
  anything that is not a field — no colour there, because colour would be a
  fifth channel in a system that already spends three.
- **Graphite** (`{colors.graphite-bar}` on `{colors.graphite-ink}`): the app
  bar, the one plane that is not paper. It is the pencil the sheet was drawn
  with, carrying the same faint warmth as the ink.

Dark mode is a register of the same sheet, not the absence of one: graphite
rather than navy, and the packet **inverts** — it is the highest-contrast object
on the screen, which is its whole job, and on a graphite sheet the highest
contrast is paper rather than more ink. Left dark it was ink on ink: present in
the markup and gone from the screen, exactly where the operator commits. The
packet
was invisible until this was fixed.

### Named Rules

**The Three Channels Rule.** Colour is spent in three channels that never meet
at the same scale. A **section** is a field — a rail, a header rule, a nav
underline — and says where you are. A **status** is a mark — a badge, a word, a
row border — and says what this thing is. An **action** is a filled control and
says what happens if you press it. Same page, three channels, so "indigo" can
never be misread as "warning".

**The Ledger's Own Answers Rule.** Green and red belong to the ledger's answers
and to actions. They are never spent on navigation or decoration.

**The Four Sections Rule.** The menu is grouped the way the operation is
sequenced and each group carries a hue, so on a phone in a storage room you know
which part of the system you are in before you read the title. Incoming is cyan
(hue 208), Operation blue (248), Stock indigo (268), and Reports is the mountain
grey (hue 82 at 0.12 chroma) — near-achromatic, because Reports is the one
section where nothing is written, only read, and it keeps the palette clear for the
instead of spending it on a menu. Three of the four are one progression along
the valley; they are not four unrelated hues.

**The Hue-Only Rule.** Only the hue is a custom property (`--section-h`,
`--section-c`). Lightness and chroma are written at the point of use, because a
custom property containing `var()` is substituted where it is *declared*, not
where it is read — deriving a tint on `:root` froze every section at the root's
hue and the whole app came out blue. The scale is five lines: rail 52%/0.15, ink
42%/0.13, scoring 48%/0.15 at 20% alpha, edge 87%/0.04, mark 72%/0.15.

**The Nav Decides Rule.** The section is derived from the current path by
longest-prefix match, never declared per screen: the nav is already the
statement of how the system is divided, and a screen free to name its own
section is free to disagree with the menu it sits under. Three screens that
belong to no group are adopted by one explicitly (`@adopted`), so no screen is
ever colourless.

**The oklab Mixing Rule.** Tints are mixed `in oklab`, never `in oklch`.
Interpolating in oklch takes the shorter hue arc, and the base white is faintly
blue — 14% of green over it came out blue and the amber's text came out red.

## Typography

**Body & Display Font:** Archivo (self-hosted variable, weight 400–700, width
62–125%), with `ui-sans-serif, system-ui, sans-serif`
**Label/Mono Font:** Chivo Mono (self-hosted variable, weight 300–700), with
`ui-monospace, SFMono-Regular, monospace`

**Character:** One family carries every role for prose, and it carries hierarchy
on its *width* axis rather than through a second face — narrow for a micro
label, open for a page title, normal for a figure. Chivo Mono is Archivo's own
monospaced sister, same foundry and same skeleton, and it does exactly one job:
identifiers. The pairing reads as the ruled technical form this app replaces.

Base size is **17px**, a step up from the web default, because this is read at
arm's length in a warehouse. A phone drops to 16px and everything is in rem, so
one declaration takes the type, the fields, the buttons and the row heights down
together — which puts another line of the list on a 390px screen instead of the
same line in larger type. It stops at 16px and not below: under 16px iOS zooms
the page the moment an input takes focus, and a screen that jumps while somebody
is typing a count is worse than a screen that fits less.

### Hierarchy

- **Display / page title** (600, 1.5rem, width **112%**, `+0.004em`): the one
  place in the app where type takes space rather than saves it. It was 87% —
  condensed, which reads as a form somebody had to fit into a box. This sheet
  has room, and this is the drawing's own title block.
- **Headline / panel title** (600, 1rem, width 92%, `-0.015em`): the container's
  name. Narrower than the title above it and than the data below it.
- **Title / figure** (600, 1.75rem — 1.25rem dense —, width 100%, line-height
  1.05, tabular): the reading a screen is worth knowing by. Normal width so the
  digits keep their full counters. Quantities used to be set in body type at
  body weight, the same ink as the word above them; a figure is the content, not
  a caption on the way to it.
- **Body** (400, 1rem/1.5): everything else. Tabular figures inside tables,
  numeric inputs and anything marked `.tabular-nums`.
- **Label / legend** (Chivo Mono, 500, 0.625rem, `+0.11em`, uppercase): the
  mono legend that names a field above its value, the way every crease chart
  names SHEET, PATTERN, MATERIAL, RATIO in the margin. Mono rather than condensed
  Archivo so a legend is never mistaken for short body copy: the two faces answer
  "is this a label or a value" before either has been read.
- **Code / crease id** (Chivo Mono, 0.8125rem in a table cell, 0.75rem uppercase
  with `+0.04em` as a box code): lot numbers, invoice numbers, GTINs, box codes.

### Named Rules

**The Crease-Id Rule.** Every identifier this operation says out loud — box
code, lot, GTIN, invoice number — is set in Chivo Mono. You read them character
by character, compare them down a column, and copy one onto cardboard in marker
pen. A proportional face makes 0 and O argue and lets L2000 and L2009 look alike
at a glance; a mono ends both arguments and lines the column up for free.

**The Box-Code Label Rule.** A box code is a printed label, not a word:
condensed mono, uppercase, tracked, on a faint field with a solid edge in the
section's own hue, boxed on all four sides. A 2px left border on a chip this
small stopped reading as a label and started reading as a stray bracket in the
middle of the sentence — the failure mode of every accent bar applied to
something narrower than it is tall. A lot number takes the face and nothing
else, because it is only ever read, never shouted. "No box" is a real and
temporary state, drawn as the same slot with a dashed edge and no fill.

**The Legend-Not-Kicker Rule.** The mono legend labels a *value* — a field cell,
a menu group, a stat. It is never a kicker or eyebrow set above a page title or
a panel heading. A page title names itself; a label above it is a second title
that says nothing.

**The Tabular-Everywhere Rule.** Figures align. Tables, numeric inputs, table
cells (`tnum`), and the identification block all carry tabular figures — the
four readings in one ruled strip are read down as much as across, and a strip of
readings whose digits do not align is a strip nobody trusts.

## Layout

**Three planes.** Ground (`sheet-ground`), panels sitting on it (`sheet-white`,
1px `mountain-grey`), and the app bar above both (graphite, sticky, 3.5rem,
constant across sections). The old world had one plane — panels were the same
white as the ground, separated by a hairline — and that is where the flatness
came from.

The page opens with a **page header**: a 1px section rail, the title, and a
hairline rule in the section's hue, with 60° scoring behind it. No fill. A
tinted band at the top of every screen competes with the data underneath. The
header is a fixed shape — `items-start` and a 3.5rem floor — so the title lands
at the same y on all twenty-six screens; with `items-end` it sank whenever a
screen had no subtitle or a tall button beside it, and a heading that moves
between pages reads as twenty-six layouts rather than one.

**First viewport:** the identification block, then the day's work as ruled
lines. `field_block/1` is a 2-column grid that becomes 4 at 1024px, closed top
and bottom by a hairline, with rules only *between* cells — the last cell in a
row has none, so the block ends on the sheet rather than in a box. Nothing is
boxed and nothing has a corner. Under it, `.quick-row` is a flex strip of the
day's acts sharing 1px gaps over a `mountain-grey` background, so the row reads
as linked panels rather than separate buttons. Flex rather than a five-column
grid because the row is filtered by role, and a fixed track count leaves a hole
where the act somebody is not allowed to perform would have been.

**Rhythm.** Panel body 1rem; panel head `0.75rem 1.75rem 0.75rem 1rem` (the
right inset is ordinary, since a panel title has nothing to run under. The
fold); table cells `0.75rem`; chip and hairline gaps `0.375rem`. Field cells are
inset from the rule rather than from a border, which is what makes the figures
line up with the prose above and below the block.

**Control sizing.** `--size-field` and `--size-selector` are both **0.21875rem**,
so an input, a select and the button beside it are all 2.1875rem — 37px at the
17px base. One token sizes all three, which is the whole reason it is a token.
It was 0.25rem (42px) and that read as a tablet kiosk: the fields dwarfed the
values inside them and a two-control row ate a third of a phone's height. The
complaint that produced 42px was never about the field — it was a small checkbox
beside a tall input, and `.check-field` fixes that by giving the box the field's
own height and border.

**Breakpoints.** 640px (base type to 16px, and the app bar drops the
organisation's name), 768px (`48rem` — the data table's two shapes), 1024px (the
identification block goes to four columns).

**A panel never widens what holds it** (`min-width: 0`). A grid item refuses to
shrink below its widest unbreakable content, and a panel's content is forty
characters of catalogue name with no spaces: a panel in a one-column grid at
390px measured 907px and stretched the container and the document with it, so
the overview scrolled sideways and the quantity column sat off the right edge of
the phone. The number those panels exist to show was the part that left the
screen.

### Named Rules

**The 44px Rule.** Below 768px every control inside a data-table row — button,
input, select — has a 2.75rem minimum, and a square icon button gets the width
too. This is CLAUDE.md's fifth recorded mistake in a different hat: the rule was
written for a field typed into one-handed, so a `btn-sm` row action kept its
desktop 1.75rem and came out a 28px target on a phone, in a warehouse, with the
next product already under the thumb. A row action is a thumb target whether or
not there is an input beside it.

**The Reserved-Slot Rule.** Anything conditional inside a row is always
rendered and hidden with `invisible`, in a slot of a fixed width, and both
controls that share a slot take the same size *and* the same width (`w-full`).
Natural widths made a 110px "Desativar" and a 119px "Reativar" land on different
edges as the list was filtered, which is the same flicker the fixed slot was
introduced to stop.

## Elevation & Depth

**This system has no elevation shadows, and that is a rule rather than an
omission.** Panels carry no shadow; the identification block carries no card;
nothing lifts on hover. Depth is three tonal planes plus one piece of drawn
geometry. The only `box-shadow` declarations in the system are not shadows at
all: an inset hairline under a focused field, an inset 2px underline marking the
active nav tab, and an inset 1px ring on the mark.

Depth is expressed instead by the **fold**. A panel's top-right corner is turned
back: two triangles, one showing the ground through where the corner is gone and
one drawn as a gradient across the underside of the turned corner
(`--fold-face-near` → `-mid` → `-far`, lit from the same side as everything else
on the page). A flat fill there reads as a grey triangle somebody drew; the
gradient is what makes it read as paper. It is drawn and not clipped, because
`clip-path` on the panel would cut every dropdown and tooltip that opens inside
it, and this app has both.

The one dropdown menu in the app does carry daisyUI's `shadow-lg`. That is an
overlay separating itself from the page beneath it, not a resting surface
claiming height.

### Named Rules

**The Flat Panel Rule.** A panel has no turned corner. The dog-ear shipped as
the world's signature on the container and was wrong twice: it repeated on
every panel — eight on the overview, so the material became a motif — and it
was ornament on the one element that should be silent. A panel holds a table
steady. The world lives where it does work: the scoring on the page head, the
crease on a movement, the chamfer on the one control that writes.

**The Press-Don't-Lift Rule.** A sheet does not float. Interactive surfaces
respond by pressing into their crease — a linked field cell, a quick action and
a table row all take the valley wash on hover — never by rising, growing or
casting a shadow. A hover lift promises an affordance the element usually does
not have, and a control that grows while it works moves the row under the thumb.

## Shapes

The form language is a ruled sheet: hairlines, right angles, and two radii that
are both tokens.

**Radii.** `box` 0.375rem for a panel, a card, a tinted note, a drop zone;
`field` 0.25rem for an input, a select, a button; `selector` 0.1875rem for a box
code chip; a full pill (999px) for the two chip forms only. Tight, because soft
corners read as friendly and this is a tool. Tailwind's `rounded-lg` is 0.5rem —
a third radius nobody decided on — and it does not belong here.

**Borders are creases.** 1px `mountain-grey`, everywhere, and never thicker. The
page rail is 1px, deliberately: four pixels of colour down the left of a page
header is the accent-rail reflex, saying "this block is important" about a block
that is simply the title. The scoring behind the title and the rule under it
already name the section twice; the rail's job is to start the reading, and 1px
starts it.

**The 60° score.** Every page header carries `repeating-linear-gradient(60deg,
…)` at 1px on an 1.1875rem pitch, masked out over the last 22% of the band. That
angle — `ANG-60` — is constant across the app: a section changes the *hue* of the
scoring, never its angle, because the angle is the identity and the hue is the
wayfinding. It sits at 20% alpha because at 13% under a shorter mask it read as
a rendering artifact rather than as a material — the thing you notice and assume
is a bug. A score line is meant to be seen; it is the mark of a sheet that has
been measured.

**The chamfer.** One shape in the app is cut at the fold angle: the packet, and
the leading edge of the quick row's strip. Everything else is a rectangle.

## Components

`CoreComponents` holds what Phoenix generates — flash, form inputs, `icon/1`,
`button/1`, `commit_action/1`. `EstoqueOSWeb.UI` holds what this operation
decided.

| Component | Use |
|---|---|
| `header/1` | the page band: title, subtitle, actions, section rail, back. One per screen. |
| `panel/1` | **the** container. Title, note, actions, `flush` for tables. No icon: the title already says what it is. |
| `field_block/1` + `stat/1` | the identification block and its ruled cells. |
| `status/1` | the closed status vocabulary. |
| `check/1` | a checkbox the size of the field beside it. |
| `filter_chips/1` | a filter that takes several answers at once. |
| `box_code/1` | the printed box label, and the dashed slot when there is none. |
| `toolbar/1` | search + filters above a listing. |
| `empty/1` | nothing here — and why, and what to do about it. |
| `data_table/1` | the record table, with `:foot` totals and `:empty`. |
| `amount/1` | an amount that follows the eye in the bar. |
| `commit_action/1` | the packet, and the dialog behind it. |
| `Movement.movement_badge/1` | a ledger movement: hue for kind, stroke for direction. |

`.panel`, `.panel-head`, `.panel-body` and `.field-row` also exist as plain CSS
classes, so a `<form>` that needs to be a panel wears the same clothes as the
`<section>` that is one.

### Buttons

- **Shape:** field radius (0.25rem), 2.1875rem tall, matching the input beside
  it. One exception: the packet, which is chamfered.
- **Resting (no variant):** soft valley blue. Present, not the loudest thing in
  the room. This tier had three spellings once — `btn-outline`, a bare
  colourless `.btn`, and the soft primary — and the bare one was the worst,
  because a `base-200` control on the `base-200` ground does not read as a
  control. Twenty-two of them across fifteen screens are one spelling now.
- **`primary`:** solid valley blue. The forward action: search, create, save,
  go on.
- **`commit`:** writes to the ledger. Via `commit_action/1` it is the packet.
- **`danger`:** solid error. Removes, deactivates, cancels. Never the resting
  focus of a screen and never the same colour as the button beside it that
  commits.
- **`ghost`:** no fill — dismiss, cancel a dialog. **Except beside the packet**,
  where it takes the sheet's own edge and a white fill: once the packet took
  solid ink and a chamfer, the ghost next to it read as a sentence somebody had left
  on the page. A control that does not look like a control is the Operate
  failure the whole mode exists to prevent, and it was introduced by making its
  neighbour loud.
- **Focus:** 2px `sheet-ink` outline at 2px offset, on every button, summary and
  link. No colour.
- **Working:** a stripe animating across the pressed control, at its exact size,
  with pointer events refused. No spinner glyph, because a glyph is width and
  width moves the row. With `prefers-reduced-motion`, the animation is dropped
  and the control states it by dimming instead.

Colour says what the button *does*, not how important it is. Size follows where
the control sits: a page's own actions in the header are unsized; an action
scoped to one card or row is `btn-sm`; an icon-only control repeated down a list
is `btn-ghost btn-square btn-sm`. Classes are written `btn` → colour → shape →
size, so the same control greps the same way on every screen.

**The button is the component, and it never takes a colour in `class`.**
`button/1` *adds* the caller's class to what makes a button, so a colour passed
in `class` joins the variant instead of replacing it: four controls on the login
confirmation screen shipped `btn-primary btn-soft` **and** `btn-primary`, and
which won depended on stylesheet order. Colour goes in `variant`; `class` is for
layout.

**A link goes to another page. A button does something to this one.** That is
the whole rule for `<.link navigate>` versus a `.btn`, and it is the only rule an
operator needs to answer "is this clickable, and what happens" without reading
the word first. A plain link that fires a `phx-click` and stays on the page is
always this bug, not a style choice.

### The Packet (signature component)

In the crease chart the packet is the folded sheet, hand-sized, the
whole structure held closed until somebody pulls it. Pulling it is the only
irreversible act, and this app has exactly one class of irreversible act — a
write to the append-only ledger.

So `commit_action/1` with tone `:commit` and no icon renders the packet: cut at
the fold angle on its trailing edge (`clip-path` with a 0.5rem pull, and the
padding opened by the same amount so the label is not clipped), faced with the
`--packet-face`, paper-on-ink at weight 600, no border, no shadow. Hover
brightens by 6%. **Pressed is the pull** — `translateX(1px)` and a hair darker,
not a lift, because a fold does not rise off the table when you tug it. Disabled
drops to the flat mountain fill: no packet where nothing can be committed. Its
tooltip lives on the wrapper, because a disabled button swallows pointer events
and its own `title` never appears.

**The Scarce Packet Rule.** The packet is `:commit` only, never `:danger`, and
never an icon trigger. `:danger` repeats down a table — a kit recipe has
twenty-eight Remove buttons, and twenty-eight chamfered ink blocks is the shouting
this component exists to avoid. An icon trigger is what a commit becomes when it
repeats on every row, and twelve chamfers down a list would say
"irreversible" twelve times on a screen where it is true once. The review asked
for the chamfer on every control; it was refused, because the gesture's whole
meaning is that there is one of it per screen.

`commit_action/1` colours its trigger **and** its dialog's confirm from one
tone: a red trigger opening a green confirm tells the operator, at the last
possible moment, that the thing they were warned about is safe after all. The
trigger is soft, the confirm is solid — loud belongs on the button that actually
does it. **The dialog carries no form of its own:** its backdrop is a
`<button class="modal-backdrop">` named by `aria-label`, not the
`<form method="dialog">` daisyUI documents, because four screens render the
dialog inside a form and the HTML parser drops a nested form outright — the
backdrop vanished with click-outside-to-close, and the button inside it was
reparented onto the page as a stray "Fechar". A component test holds this, since
the markup is correct and the browser rewrites it.

### Status

**A screen names a state; it never picks a colour.** The list is closed — a
state that is not in `UI.status_spec/1` is a state nobody has agreed on yet, and
adding one is a decision made once, there.

**Two registers, and choosing between them is the design decision, not the hue.**

- **A fact about the goods** — bought, donated, controlled, presumed, no box, in
  transit, counted, complete, under way — is *quiet*: a 0.375rem dot in the
  state's colour and the word beside it in ordinary ink, no fill, no padding.
  The quantity beside it stays the loudest thing on the row.
- **Something wrong, now** — expired, expiring, a count that disagreed twice,
  not linked, below minimum, needs review — keeps the fill. Colour is the alarm,
  and an alarm that fires on nine rows in ten is not an alarm.

`:controlled` is the one worth explaining: a Portaria 344 substance is not a
problem and not a warning, it is a legal class that changes who may touch the
box. It is quiet with an *ink* dot rather than a hue, so it never reads as
"something went wrong" and never blends into the amber of an expiry date. Eight
screens had independently picked `badge-error` for it.

`:stale` is deliberately muted — most boxes in a real warehouse are stale.
`:donation` is the accent, spent where the work is humane. **"Presumed" is words
on the stock table, not a badge**: it was a 10px ghost badge once and became the
least visible thing on a screen whose entire claim is that it separates counted
from inherited. `stock_filter_test.exs` holds this.

**No icons on badges.** At 12px, repeated dozens of times down a table, they are
texture rather than information. The word carries the meaning and the
accessibility.

### Mountain and Valley (signature component)

The one idea this world hands the product for free. `Movement.movement_badge/1`
draws a ledger movement in **two channels**: the closed four-colour hue
vocabulary carries the *kind* of movement (arrived / left for good / moved
without changing hands / the ledger corrected itself), and a 2px stroke on the
badge's leading edge carries the *direction*, which is what somebody scanning a
column of forty movements is actually asking.

- **`fold-in`** — a solid stroke. Goods arriving, the valley pressed into the
  sheet.
- **`fold-out`** — the same stroke broken: `currentColor 0 2px, transparent
  2px 3.5px`. Goods leaving, the mountain raised. Fine dashes and not two long
  ones, because a badge is about 20px tall and a 3px dash with a 2.5px gap put
  exactly two marks in that height, which reads as a colon rather than a broken
  rule.
- **Nothing at all** where no goods crossed a door. An adjustment is
  deliberately creaseless: the ledger corrected itself, and drawing a fold on it
  would claim a direction the transaction does not have.

The stroke is a second channel, never the only one. The text always says which.

### Cards / Containers

There are no cards. `panel/1` is the one container: sheet white, one 1px
mountain-grey edge, `box` radius, no shadow, no turned corner, 1rem
body padding, `flush` when the body is a table so the cells' own padding does the
work. Its head takes the panel's corner radii when the body is flush.

### Inputs / Fields

- **Style:** sheet white, 1px mountain-grey, `field` radius, 2.1875rem tall.
- **Focus:** the field sits in its crease — valley-wash fill, valley-line
  border, and an inset hairline at the top. No outline ring.
- **Checkbox:** `.check-field` gives the box the field's own height, border and
  radius, so in a form grid a checkbox row and a text field are the same object,
  and on a phone the whole row is the tap target rather than a small square
  somebody has to aim at while holding a box. Checked tints the whole field 7%
  primary.
- **`.field-row`** is the row where some controls carry a label and some do not.
  daisyUI's `.fieldset` puts 4.25px of padding below its field, so `items-end`
  aligned a bare button to the bottom of the *label's box* rather than the input
  inside it, and every button in the app sat five pixels lower than the fields
  beside it. Measured, then fixed.
- **Searching:** a `phx-change` form's search input grows a sweeping 2px
  underline in primary while the server looks, because "nothing matched" and
  "still typing" looked identical and the operator retyped a name that was
  already on its way.
- **An input inside a `phx-change` form always renders its value from assigns**,
  empty string rather than nil. Without it the server's repaint blanks the field
  and the operator watches the number they are typing vanish.

### Chips

Two forms of the same object, both fully rounded.

- **`chip-check`** — a filter that takes several answers at once. The native
  `<select multiple>` wants a modifier key that a phone does not have. The
  checkbox is kept in the accessibility tree with `sr-only`, and `:has(:checked)`
  paints the chip: its group's colour at 14% over white, that colour at 45%
  strength as the border, weight 500. Laid out in a **grid, not a wrapping row** —
  ticking a chip makes it a shade heavier, a wrapped row re-flows, and every chip
  after it moves, including the one the thumb was already over. Fixed cells cannot
  move; only their colour changes. It caps at 10.5rem and scrolls, because a panel
  taller than the phone is a panel with an Apply button nobody reaches.
- **`chip-drop`** — the same chip after the fact, outside the panel that set it,
  wearing its group's colour, with an × that drops that one and leaves the rest.
  Hovering it turns the whole chip to error, because that is what the click does.

### Navigation

Graphite bar, sticky, 3.5rem, `z-40`, one hairline edge. Controls in it are told
their colour directly rather than through the theme, because daisyUI derives
button colour from `base-content`, which is ink-on-paper. **The active tab takes
the valley wash as an inset 2px underline in the section's hue** — the board's
own answer for a selected cell.

A dropdown hangs off the bar in the DOM but is painted on paper, so its buttons
are re-told the paper colours. Without that, the bar's near-white ink went into
the menu and the "view as" buttons came out at 1.05:1 on a white panel —
present in the markup, invisible on a light theme, and fine on a dark one, which
is how it got past review.

**Navigation names places, not steps.** The menu lists where you can *be*.
Importing an invoice is something you do once you are already in invoices, so it
lives on that screen and not in the bar. A filter's "no filter" option names its
dimension (`Todos os locais`) rather than sitting blank: an empty option reads as
a control that failed to load.

**Going back is one control, and it is `header/1`'s.** Every screen that is one
specific record drilled into from exactly one list carries `back_to`/`back_label`
top-left, next to the section rail, rendered as a `.btn.btn-ghost.btn-sm` — a
real button with a hover box, not a quiet inline link, because it is the one
control every screen shares and it had been the exception to "a button looks
like a button". The label is always the destination's own name (`Estoque`,
`Notas fiscais`), the same string the nav uses for that place, never a "back
to…" sentence. Three styles and two positions for this question had shipped at
once, which is why it stopped reading as a pattern. A screen that is itself a
place in the nav does not get one: it is not drilled into from a list, it *is*
the list.

### Data Table

One DOM, two shapes. A desktop table and a mobile card list written as separate
markup would duplicate every id inside a cell, which is invalid HTML and breaks
LiveView — so the table **collapses into blocks with CSS** below 48rem: identity
on top and full width, context beneath, the number that matters loud on the
right, each cell's label rendered from `data-label` in front of its value.

- **No zebra striping.** Alternating fills say "record set"; these rows are
  positions of real stock.
- **Column labels are scaffolding, not content.** They carried four emphases at
  once — uppercase, semibold, near-full contrast, on a flat slab cut off by a
  hard rule — for text whose whole job is to name the column under it. What is
  left is the smallest thing that still reads as a label: 0.75rem, weight 500,
  about half the ink, a breath of tint and a hairline. **Sentence case,
  deliberately** — the uppercase only ever applied to non-sortable headers,
  because a sortable header renders a `button` and that reset the transform, so
  half the app shouted and the other half did not.
- **The header sticks** under the app bar, opaque. Forty-five rows of stock
  scrolled past a header that left with them.
- **A sortable header darkens its ink on hover, and never grows or moves** — a
  header that changes size shifts the column under the cursor.
- **Money never wraps.** A value broken across two lines reads as two numbers.
- **`group`** draws a rule between column families — what it is, where it is,
  what it is worth — rather than a border around every cell.
- **`emphasis={:code}`** sets a cell in Chivo Mono: a lot number, an invoice
  number, a GTIN. Same argument as the box code, without the printed label.
- **`width`** sets explicit column widths; auto layout gives the longest text the
  most room, which on a stock table means the product name takes half the width.
- **`<th>` is left-aligned.** Its default is centre, which had every header
  floating over the middle of a column of left-aligned values.
- **`:foot`** carries totals; a table that ends without saying what the set adds
  up to makes the reader do arithmetic the system already did. Totals skip nils
  rather than treating them as zero — a donation with no informed value is
  unknown, and adding it in as nothing understates the page.
- **`:empty`** carries an `empty/1`, never a bare sentence. An operator who
  reaches a blank screen has either finished the work or taken a wrong turn, and
  a blank page cannot tell them which.
- **A preload rendered as a list gets an explicit `order_by`**, in the order the
  paper uses. Postgres returns rows however the plan produced them, so an updated
  row moves and the operator watches line 4 jump to the bottom.

### The Notice Stack

Every notice is a row in one fixed column at the bottom right, and it leaves by
**folding** rather than by disappearing: `1fr` → `0fr` on a one-row grid, plus
opacity and a 1.5rem translate out toward the edge it came from, so the stack
reads as a queue draining rather than as notices evaporating in place. They used
to be two separately-positioned toasts pinned to the same corner, so an error
landed exactly on top of the confirmation underneath it. With reduced motion the
transition is dropped entirely — a notice that lingers half-faded is worse than
one that is simply gone.

### Hidden amounts

The eye in the bar swaps which of two spans is shown: the amount, or `R$ ••••`
at `+0.08em` and 55% opacity. Two spans rather than dots positioned over the
number, because a cell is `display: flex` on a phone and `table-cell` on a laptop
and absolute positioning breaks in one of them. Never a blur — a blur still says
"a number is here, lean closer".

**It starts hidden, always**, applied before first paint so the amounts never
flash on and then vanish. The choice lives in `sessionStorage`, so revealing
lasts while you work and a new browser starts covered. **Not a security
control:** the real amount is in the markup either way, and what keeps a price
from a partner outside the ONG is not rendering it at all.

## Do's and Don'ts

### Do:

- **Do** put every identifier the operation says out loud — box code, lot, GTIN,
  invoice number — in Chivo Mono, and every quantity in tabular figures.
- **Do** carry hierarchy on Archivo's width axis: 112% for a page title, 92% for
  a panel title, 100% for a figure. A second family is never the answer.
- **Do** keep the three colour channels apart by scale: section is a field,
  status is a mark, action is a filled control.
- **Do** give every state a **word**. Colour and the fold stroke are second
  channels; neither is ever the only one.
- **Do** use `panel/1` for anything that needs a container, `field_block/1` for
  the readings a screen opens with, and `status/1` for any state.
- **Do** reserve the space for anything conditional inside a row, at a fixed
  width, and check it at the width the phone actually uses.
- **Do** hold the 44px floor for every control inside a data-table row below
  768px — buttons included, not only fields.
- **Do** mix tints `in oklab` and write section lightness and chroma at the point
  of use.
- **Do** keep everything brand-bearing inside the four places named in the
  provisional-identity table.

### Don't:

- **Don't** add a KPI-card row, a floating tile, or any resting surface with a
  drop shadow. The identification block replaced exactly that, and hover lift
  promises an affordance that usually does not exist.
- **Don't** give a panel a turned corner, or a page a second element with
  one where one sheet would do.
- **Don't** put the chamfer on anything but the single `:commit` trigger
  per screen. Not on `:danger`, not on an icon trigger, not on a secondary
  action.
- **Don't** ship the 60° scoring at a different angle per section, or a section
  rail wider than 1px.
- **Don't** paint a status by colour alone, put an icon inside a badge, or give
  a "fact about the goods" a filled badge.
- **Don't** introduce a third radius. `box`, `field`, `selector` and the pill are
  the whole set; `rounded-lg` is not one of them.
- **Don't** set a mono legend above a page title or a panel heading as a kicker.
  It labels a value, never a heading.
- **Don't** pass a colour class to `button/1` in `class`; it joins the variant
  rather than replacing it, and stylesheet order decides which wins.
- **Don't** let a control change size while it works, or grow when it is
  confirmed. Stripes, not spinners.
- **Don't** spend green or red on navigation, or amber anywhere near the accent.
- **Don't** ship a raster asset for the mark or any brand surface.

## What is not decided

- The real brand assets, and everything in the provisional-identity table that
  waits on them.
- Whether the packet should keep its one-act-per-screen discipline once the ONG
  sees it in use.
- An accessibility standard to test against. Honored today: labelled controls,
  keyboard-reachable actions, a visible focus treatment on every control, status
  conveyed by text and never by colour alone, icon-only buttons carrying
  `aria-label`, `prefers-reduced-motion` handled on all three waiting signals,
  and a 2.1875rem minimum control height rising to 2.75rem for anything in a row
  on a phone.
