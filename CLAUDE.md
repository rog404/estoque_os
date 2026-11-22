# CLAUDE.md — Estoque Operação Sorriso

Read `docs/SPEC.md` before doing anything. It is the source of truth for
domain, design decisions and phases. Sample documents are in `priv/samples/`
(2 NF-e XMLs, 1 CC-e, kit definitions, standard supply table) — real in shape,
fictional in party: this repository is public, so the companies, registrations
and people in them were replaced.

## Hard rules

- Elixir + Phoenix LiveView + PostgreSQL + Tailwind.
- ALL code, schema, table, column, module and function names in **English**.
- ALL user-facing strings in **Brazilian Portuguese** through Gettext
  (default locale `pt_BR`). No hardcoded Portuguese in code; no English
  leaking into the UI.
- Stock is an append-only ledger: `transactions` + `transaction_entries`.
  NEVER store or mutate a balance directly; balances are derived (a snapshot
  table may exist as a transactionally-maintained cache only).
- Every stock change has a transaction type and, for adjustments, a reason
  code. Nothing is hard-deleted.
- Money = Decimal. Unit costs may be NULL (donations) — never 0.01.
- Lot-level tracking everywhere; FEFO as default picking suggestion.
- Boxes are movable containers with `last_verified_at`; moving a box does not
  require recounting it.
- NF-e parsing: one parser for layout 4.00 behind an importer behaviour
  (`Invoices.Importers.NFe`). Extraction order: `rastro` group → `infAdProd`
  regex → flag `needs_review`. Parser must pass tests against both XMLs in
  `priv/samples/`. Reach them through `EstoqueOS.Samples`, never a relative
  path — a release has no working directory to be relative to.

## Five mistakes this codebase has already made

Each of these shipped at least once and cost real time. They are cheap to avoid
and invisible in review.

**A `preload` with no `order_by` reorders itself.** Postgres returns rows however
the plan produced them, so an *updated* row moves — the operator types into line
4 of a conference and watches it jump to the bottom. Hit three times: receipt
lines, invoice items, mission returns. Any preload whose rows are rendered as a
list gets an explicit `order_by`, and the order should be the one the paper uses
(NF-e line number, box code) so the screen matches the document beside it.

**`refute html =~ "..."` matches markup, not text.** `"300"` is inside
`border-base-300`; `"-13"` is inside `id="line-13"`; `"-2"` is inside `w-28`.
Every blind-count and permissions test that asserts something is *absent* must
strip tags first — `String.replace(html, ~r{<[^>]*>}s, " ")` — or scope to one
element. A refute that passes on luck is worse than no test, because it is the
test protecting the rule.

**`mix gettext.extract --merge` guesses and marks it `fuzzy`.** It does not leave
new entries blank; it writes a similar existing translation in, and `fuzzy` does
not stop it rendering. `Import data` came out as "Importar", `recorded` as
"Registrar". Use `/i18n` after any change that touches a `gettext(...)` call, and
read every fuzzy entry rather than clearing the flag.

**A HEEx `<!-- -->` comment is shipped to the browser.** It is in the rendered
HTML, so a `refute html =~ "..."` finds the word in *the comment explaining why
the word is not there*. Three times in one session: "vencendo" in a comment
about the filter panel, "Caixas para recontar" in one about a hidden panel,
"vencido" in one about a new filter option. Explain the behaviour without
quoting the user-facing string, or use `<%!-- --%>`, which is not rendered.

**A control that appears on save moves the row under the operator's thumb.**
Reported four times now (B3, C1, N1, and the "Contar de novo" button that wrapped
onto a second line on the counted row only). These screens are used one-handed,
standing up, with the next line already under the thumb — a row that grows when
it is confirmed sends the next tap to the wrong product. Anything conditional
inside a row is *always* rendered and hidden with `invisible`, in a slot of a
fixed width, and the slot is checked at the width the phone uses. Reserving the
space is the fix; `:if` inside a row is the bug.

**An input with no server-rendered `value` is emptied by `phx-change`.** The
form repaints on every keystroke, and the server's answer for a field it does
not track is blank — so the operator watches the number they are typing vanish.
Hit twice: the receiving conference (fixed with the `drafts` map) and the
write-off quantity, where it also made the FEFO preview look like the cause. Any
input inside a `phx-change` form renders its value from assigns, empty string
rather than nil so the attribute is always there to read.

## Workflow

- Follow the phases in SPEC §9; do not start Phase 2 features while Phase 1
  is incomplete, unless asked.
- Write tests alongside features; ledger invariants and the NF-e parser are
  the highest-priority test targets.
- Prefer boring, readable Elixir. Contexts: `Catalog`, `Inventory`,
  `Invoices`, `Kits`, `Reports`, `Accounts`.
- When a product decision is ambiguous, ask instead of guessing — the user
  (Rogerio) is the product owner and talks to the ONG team.

## Git workflow (Conventional Commits)

**This project works in branches and merges through PRs.** Decided 2026-08-20;
it used to commit straight to `main`, and that is over.

There is a remote (`origin`, github.com/rog404/estoque_os) and `gh` is
authenticated, so a PR has a reader and a place to live.

- Branch per piece of work, named `feat/short-desc` (or `fix/`, `chore/`,
  `refactor/`). Never commit on `main`.
- Open a PR with `gh pr create`. **Put images in the PR when the change is
  visible** — run the app (`/run-app`), screenshot the screens the PR changes,
  and embed them in the body. A UI change described in prose is a UI change
  nobody reviewed.
  - `gh` cannot attach an image the way the web UI can, so the screenshots live
    on the orphan branch **`pr-shots`** (`shots/*.png`) and the body links
    `https://raw.githubusercontent.com/rog404/estoque_os/pr-shots/shots/NAME.png`.
    Build it from a throwaway worktree (`git worktree add --detach`, `git
    checkout --orphan pr-shots`) so `main` never carries a PNG.
- **Never add a `Co-Authored-By` trailer.** The commits are his.

**Conventional Commits (required):** `type(scope): description`, referencing
the GitHub issue (`#N`) when there is one. Types: `feat`, `fix`, `chore`,
`refactor`, `docs`, `perf`, `test`, `ci`, `build`, `style`, `revert`.

## Agent skills

### Issue tracker

Issues live as GitHub issues in rog404/estoque_os, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root (neither exists yet — created lazily by `/domain-modeling`). See `docs/agents/domain.md`.
