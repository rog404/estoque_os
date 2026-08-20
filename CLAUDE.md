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

## Four mistakes this codebase has already made

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

**A control that appears on save moves the row under the operator's thumb.**
Reported four times now (B3, C1, N1, and the "Contar de novo" button that wrapped
onto a second line on the counted row only). These screens are used one-handed,
standing up, with the next line already under the thumb — a row that grows when
it is confirmed sends the next tap to the wrong product. Anything conditional
inside a row is *always* rendered and hidden with `invisible`, in a slot of a
fixed width, and the slot is checked at the width the phone uses. Reserving the
space is the fix; `:if` inside a row is the bug.

## Workflow

- Follow the phases in SPEC §9; do not start Phase 2 features while Phase 1
  is incomplete, unless asked.
- Write tests alongside features; ledger invariants and the NF-e parser are
  the highest-priority test targets.
- Prefer boring, readable Elixir. Contexts: `Catalog`, `Inventory`,
  `Invoices`, `Kits`, `Reports`, `Accounts`.
- When a product decision is ambiguous, ask instead of guessing — the user
  (Rogerio) is the product owner and talks to the ONG team.
---

## ⚠️ MANDATORY RULES (MUST FOLLOW)

These rules are **absolute** and must be followed in ALL interactions:

### 0. 🔴 TOP PRIORITY: ALWAYS use Cortex MCP Tools

**This is the most important rule of all.** ALWAYS prefer Cortex MCP tools (`mcp__cortex__*`) over CLI, Bash, Glob, Grep, or any other tool for the following operations:

| Operation | MCP Tool (USE) | Alternative (DO NOT USE) |
|-----------|----------------|--------------------------|
| Create task | `task_create` | ~~cx add via Bash~~ |
| View task | `task_get` | ~~cx show via Bash~~ |
| List tasks | `task_list` | ~~cx ls via Bash~~ |
| Update task | `task_update` | ~~cx mv via Bash~~ |
| Project status | `mcp__cortex__status()` | ~~cx status via Bash~~ |
| Get memory by ID | `memory_get` | ~~nothing~~ |
| Save memory | `memory_save` | ~~cx memory diary via Bash~~ |
| Search memory | `memory_list` | ~~cx memory search via Bash~~ |
| Link memory | `mcp__cortex__memory(action="link")` | ~~cx memory via Bash~~ |
| Search learnings | `learnings_relevant` | ~~nothing~~ |
| List learnings | `learnings_list` | ~~cx learnings list via Bash~~ |
| Create branch | `git_branch` | not used here — see §4 |
| Create PR | `git_pr` | not used here — see §4 |
| Merge PR | `git_merge` | not used here — see §4 |
| Changelog | `git_changelog` | ~~git log via Bash~~ |
| Index LSP | `lsp_index` | ~~cx lsp index via Bash~~ |
| Symbols in code | `lsp_symbols` | ~~Glob/Grep~~ |
| Global symbol search | `lsp_workspace_search` | ~~Grep/Glob~~ |
| Go to definition | `lsp_definition` | ~~Grep~~ |
| Find references | `lsp_references` | ~~Grep~~ |
| Symbol info | `lsp_hover` | ~~Read~~ |
| Replace code | `lsp_replace_symbol` | ~~Edit~~ |
| Rename symbol | `lsp_rename_symbol` | ~~Edit with replace_all~~ |
| Verify task | `mcp__cortex__verify_task(task_id="CX-N")` | ~~go build/test via Bash~~ |
| Extract rules | `business_rule_extract` | ~~manual analysis~~ |
| Epics | `epic_link_task` / `epic_tasks` | ~~nothing~~ |
| External DB | `db_query` / `db_schema` | ~~psql via Bash~~ |
| Plans | `plan_create` / `plan_get` / `plan_submit` / `plan_approve` / `plan_reject` | ~~nothing~~ |
| Brainstorm | `mcp__cortex__brainstorm(action="create/...")` | ~~nothing~~ |
| Phases | `phase_get` / `phase_update` / `phase_complete` | ~~nothing~~ |
| DoD | `dod_list` / `dod_add` / `dod_check` / `dod_init` | ~~nothing~~ |
| Agent orchestration | `agent_spawn` / `task_orchestrate` | ~~nothing~~ |
| Controller | `controller_init` / `controller_spawn` / `controller_status` | ~~nothing~~ |
| Code graph context | `mcp__cortex__codegraph(action="context", task="...")` | ~~nothing~~ |
| Build code graph | `mcp__cortex__codegraph(action="build")` | ~~cx codegraph build via Bash~~ |
| Update code graph | `mcp__cortex__codegraph(action="update")` | ~~cx codegraph update via Bash~~ |
| Query symbols | `mcp__cortex__codegraph(action="query", name="...")` | ~~Grep/Glob~~ |
| Impact analysis | `mcp__cortex__codegraph(action="impact", node_id="...")` | ~~nothing~~ |
| Change detection | `mcp__cortex__codegraph(action="detect_changes")` | ~~nothing~~ |
| Review hints | `mcp__cortex__codegraph(action="review_hints")` | ~~nothing~~ |
| Dead code | `mcp__cortex__codegraph(action="dead_code")` | ~~nothing~~ |
| Communities | `mcp__cortex__codegraph(action="communities")` | ~~nothing~~ |
| Refactor suggestions | `mcp__cortex__codegraph(action="refactor")` | ~~nothing~~ |
| Visualize graph | `mcp__cortex__codegraph(action="visualize")` | ~~cx codegraph visualize via Bash~~ |
| Generate wiki | `mcp__cortex__codegraph(action="wiki")` | ~~cx codegraph wiki via Bash~~ |
| Style guide sync | `mcp__cortex__style_guide(action="sync")` | ~~cx style sync via Bash~~ |
| Style guide status | `mcp__cortex__style_guide(action="status")` | ~~nothing~~ |
| Style guide search | `mcp__cortex__style_guide(action="search", query="...")` | ~~nothing~~ |

**Reflection tools - USE at key moments:**
- `think_about_task_adherence` → Before significant code changes
- `think_about_collected_information` → After research/code reading
- `think_about_whether_you_are_done` → Before declaring task as complete

**Exceptions (when to use native Claude Code tools):**
- `Read` → To read file contents (MCP has no file reading equivalent)
- `Edit`/`Write` → To edit/create files when LSP replace is not appropriate
- `Glob` → For quick file search by pattern (MCP has no glob)
- `Bash` → For system commands that MCP does not cover (make, go install, etc.)

**NEVER use `cx` via Bash when an equivalent MCP tool exists.**

### 1. Task Management - ALWAYS use Cortex MCP

```
# CREATE task before any work
task_create(title="Task title", type="feature|bug|chore")

# START task before implementing
task_update(id="CX-N", status="progress")

# FINISH task when complete
task_update(id="CX-N", status="done")
```

**NEVER** work without an associated Cortex task.

### 2. Sync with Claude Code Internal Tasks

When using Claude Code's internal TaskCreate/TaskUpdate:
- **ALWAYS** create the corresponding task in Cortex first with `task_create`
- **ALWAYS** keep IDs aligned (use CX-N as reference)
- **ALWAYS** update both systems when changing status

Correct flow:
```
1. task_create(...)                          → Creates CX-N in Cortex
2. TaskCreate (internal)                     → Creates internal tracking referencing CX-N
3. task_update(id="CX-N", status="progress") → Marks in progress
4. TaskUpdate status=in_progress             → Marks in progress internally
5. [work...]
6. task_update(id="CX-N", status="done")     → Marks done in Cortex
7. TaskUpdate status=completed               → Marks done internally
```

### 3. Memory - Search BEFORE asking

```
# ALWAYS search context before asking user questions
memory_list(search="relevant term")
```

### 4. Git Workflow (Conventional Commits)

**This project works in branches and merges through PRs.** Decided 2026-08-20;
it used to commit straight to `main`, and that is over.

There is a remote (`origin`, github.com/rog404/estoque_os) and `gh` is
authenticated, so a PR has a reader and a place to live.

- **NEVER** commit without an associated task.
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
- Changelog: `git_changelog(from_tag="v0.1.0")` → generates grouped changelog

The Cortex hook that blocks `git commit` on `main` is right again and should be
re-enabled (`/hooks`) — it was turned off only while the flow was commit-on-main.

**Conventional Commits (required):**

Format: `type(scope): description (CX-N)`

| Task Type | Commit Type |
|-----------|-------------|
| `feature` | `feat` |
| `bug` | `fix` |
| `chore` | `chore` |
| `debt` | `refactor` |

Additional types: `docs`, `perf`, `test`, `ci`, `build`, `style`, `revert`

The MCP generates automatically:
- **PR title** in conventional commits format (via `task.FormatCommitMessage`)
- **Squash merge message** with `--subject` in the correct format
- **Changelog** grouped by type (Features, Bug Fixes, etc.)

Validation hook (cortex-plugins) warns if commit message doesn't follow the format.

```
# Task status flow here (no `review`: there is nobody to review it):
# backlog → progress → done
#    ↑         ↑         ↑
# task(create) task(update) task(update) after the commit lands
```

### 5. Session End

At the end of a significant work session:
```
mcp__cortex__memory(action="save", type="diary", title="Session ...", content="Summary of what was done")
```

### 6. Status Check

At the start of any work, check current state:
```bash
mcp__cortex__status()                 # See project overview
mcp__cortex__task(action="list")      # See existing tasks
```

### 7. 🧠 Development Workflow - Choose the right mode

**RULE:** Before implementing, evaluate complexity and choose the appropriate mode:

```
┌─────────────────────────────────────────────────────────────────┐
│                    DECISION TREE                                 │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
              ┌─────────────────────────┐
              │ Is the solution clear?  │
              └───────────┬─────────────┘
                    │           │
                   Yes          No
                    │           │
                    ▼           ▼
         ┌──────────────┐  ┌──────────────┐
         │ Is it        │  │ /brainstorm  │
         │ complex?     │  │ "title"      │
         └──────┬───────┘  └──────────────┘
           │         │           │
          No         Yes         ▼
           │         │     Explore ideas
           ▼         ▼     Vote, decide
    ┌──────────┐ ┌──────────┐  │
    │ cx add   │ │ /plan    │  ▼
    │ + impl   │ │ "title"  │ /plan or
    └──────────┘ └──────────┘ brainstorm_to_plan
                      │              │
                      ▼              ▼
               Document         ┌──────────┐
               approach         │ cx add   │
                    │           │ + impl   │
                    ▼           └──────────┘
              ┌──────────┐
              │ cx add   │
              │ + impl   │
              └──────────┘
```

#### When to use `/brainstorm`:
- 🧠 New feature **without clear design**
- 🤔 **Multiple approaches** possible (which DB? which lib?)
- ⚖️ Need to **explore trade-offs** before deciding
- 💡 Want to **capture ideas** before committing

```bash
/brainstorm "Authentication system"
# → Adds ideas: OAuth, JWT, Session
# → Votes and selects the best
# → Converts to Plan when ready
```

#### When to use `/plan`:
- 📝 Design **already defined**, needs documentation
- 🔄 Converting **brainstorm to executable plan**
- 📋 **Complex feature** that needs a spec before code
- 👥 Needs **review/approval** before implementing

```bash
/plan "Refactor payments module"
# → Writes design/approach in markdown
# → Adds comments if needed
# → Approves and creates tasks
```

#### When to go directly to Task + `/implement`:
- ✅ Bug fix with **known cause**
- ✅ **Small feature** with clear scope
- ✅ **Well-defined change** requested by user
- ✅ Following an **already approved plan**

```bash
cx add "Fix login timeout" --type bug
/implement CX-N
```

### 8. 🤖 Agent Workflow - USE `/implement` for code tasks

**CRITICAL RULE:** For ANY code implementation task, use the `/implement` skill:

```bash
/implement CX-N              # Runs workflow for existing task
/implement "Add new feature" # Creates task and runs workflow
```

**The 3-agent workflow is REQUIRED for:**
- ✅ Implementing new features
- ✅ Fixing bugs
- ✅ Significant refactorings
- ✅ Adding tests
- ✅ Any non-trivial code change

**DO NOT use the workflow for:**
- ❌ Small fixes (typos, formatting)
- ❌ Documentation updates
- ❌ Questions about code
- ❌ Analysis/exploration without implementation

**Workflow flow:**
```
┌──────────┐     ┌───────────┐     ┌────────┐
│ research │ ──▶ │ implement │ ──▶ │ verify │ ──▶ done
└──────────┘     └───────────┘     └────────┘
     │                │                 │
     ▼                ▼                 ▼
  Understands      Writes           Tests and
  codebase         code             validates
  + creates plan   + follows plan   + completes
```

**MCP commands used:**
```
agent_spawn(task_id=task_id)              # Start agent
agent_report(session_id=..., status=...)  # Report progress
agent_sessions()                          # List sessions
```

### 9. 🔍 LSP Tools - Use Cortex for code analysis

**RULE:** For code analysis (symbols, definitions, references), use **Cortex MCP** LSP tools:

```
lsp_symbols(file=file)                                         # Symbols in file
lsp_workspace_search(query=query)                              # Global symbol search
lsp_definition(file=file, line=line, column=column)            # Go to definition
lsp_references(file=file, line=line, column=column)            # Find references
lsp_hover(file=file, line=line, column=column)                 # Symbol info
lsp_replace_symbol(file=file, symbol_name=symbol)              # Replace code
lsp_rename_symbol(file=file, line=line, column=column, new_name=name)  # Rename
lsp_index(language=language)                                   # Trigger indexing
```

**DO NOT use external plugins** for LSP (serena, gopls-lsp, rust-analyzer-lsp) - Cortex already integrates gopls and rust-analyzer internally.

**Supported languages:**
- Go (via gopls)
- Rust (via rust-analyzer)
- TypeScript/JavaScript (requires installation)
- Python (requires installation)
- Elixir (via Expert, standalone binary)

**Initialization:** LSP starts automatically on first call.

### 10. 📚 Learnings System - Continuous Improvement

Cortex extracts and applies learnings automatically to improve code quality over time.

**Agents MUST fetch learnings at the start of workflow:**
```
# Research - learn from the past
learnings_relevant(task_type="feature", domain="go")

# Implement - apply success patterns
learnings_relevant(task_type="feature")

# Verify - know failure patterns
learnings_list(type="failure_pattern", limit=5)
```

**Learning types:** `success_pattern` | `failure_pattern` | `domain_knowledge` | `user_feedback`

**Requires:** `OPENAI_API_KEY` for automatic extraction

---

### 10. 📊 Code Graph — Structural code analysis via Tree-sitter

If the project has a built code graph (`codegraph:status` shows nodes > 0), use it:

```
# First call — ultra-compact overview (~100 tokens)
mcp__cortex__codegraph(action="context", task="what you are doing")

# Query symbols (case-insensitive substring match)
mcp__cortex__codegraph(action="query", name="SymbolName")

# Impact before changing code
mcp__cortex__codegraph(action="impact", node_id="cn-xxx")

# Review hints before PR
mcp__cortex__codegraph(action="review_hints", since="HEAD")

# Build/update the graph
mcp__cortex__codegraph(action="build")     # full build (first time)
mcp__cortex__codegraph(action="update")    # incremental (after changes)
```

Additional actions: `dead_code`, `communities`, `refactor`, `rename_preview`, `detect_changes`, `visualize`, `wiki`

Supported languages: Go, Elixir, TypeScript, Rust, Python

---

### 11. 🎨 Style Guide — Shared coding conventions

If the project has a style guide configured (`style_guide:status` shows configured):

```
# Search for relevant conventions before writing code
mcp__cortex__style_guide(action="search", query="naming conventions")

# Sync style guide from remote repo
mcp__cortex__style_guide(action="sync")

# Check status
mcp__cortex__style_guide(action="status")
```

Agents should search the style guide before implementing code to follow team conventions.

---

<!-- cortex-rules -->
<!-- cortex-memory-rules -->
<!-- Rules will be auto-generated here by: cx memory export -->
<!-- /cortex-memory-rules -->
