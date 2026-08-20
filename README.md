# Estoque OS

Stock control for a surgical NGO that works out of boxes.

**Operação Sorriso do Brasil** runs week-long surgical missions — cleft lip and
palate — in remote Brazilian cities. A mission is planned for four operating
tables, packed into numbered boxes, flown in, partly consumed, partly donated to
the local hospital, and partly flown home. Until now the whole thing lived in
spreadsheets, which cost the supply coordinator more than a week of work per
mission and left one question unanswerable: *what do we have, where is it, in
what state, and who moved it.*

This is the system that answers it. The interface is entirely in Brazilian
Portuguese; the code, schema and these docs are in English.

> **Status:** working prototype, deployed as a demo. Not yet running the real
> operation.

![The dashboard: what needs attention before the next mission](docs/images/dashboard.png)

---

## What it does

| | |
|---|---|
| **Ledger** | Stock is an append-only ledger of signed entries. No balance is ever stored or edited — every figure on every screen is derived, and a snapshot table exists only as a cache the same transaction maintains. Every movement has a type, and every adjustment a reason code. Nothing is hard-deleted. |
| **Lots and expiry** | Everything is tracked to the lot. FEFO is the default picking suggestion. A lot with no expiry date is a distinct fact from a lot that never had one, and the product says which to expect. |
| **Boxes** | Boxes are movable containers with their own `last_verified_at`. Moving a box moves its presumed contents — a box travels whole and is not recounted on arrival — so the screens distinguish a counted balance from an inherited one. |
| **NF-e import** | Brazilian electronic invoices (layout 4.00) are parsed, matched against the catalog and posted into the ledger at real unit costs. Lot numbers come from the structured `rastro` group when the supplier ships it, from a regex over `infAdProd` free text when they don't, and are flagged for review when neither works. Correction letters (CC-e) attach to the invoice they correct. |
| **Receiving** | Conference against what the invoice promised, blind or not, in rounds — because the warehouse recounts when a divergence looks like a miscount. |
| **Kits** | A kit is a product. Assembling one converts component lots into a lot of the kit's own product, so the screen that writes off a bandage writes off a kit, and a recall can still trace which component lots went into which kit lot. Assembly is refused outright while any component has expired stock on the shelf — a kit is sealed, and nobody opens one to read a date. |
| **Missions** | One trip at a time in one place, enforced by a Postgres exclusion constraint rather than a check in Elixir — the race it prevents is invisible to application-level validation. Load-out, on-site consumption, donation and return, with stock that goes straight from one mission to the next accounted for as *moved on* rather than lost. |
| **Two stocks** | Surgical supply and marketing material live in one ledger, told apart by the product's `segment`. Marketing is sold rather than consumed, so it leaves with a price on the way out, and the role that looks after it sees that stock and nothing else — enforced in the queries, not in the templates. |
| **Money** | Five roles. The operator who handles boxes never sees a price, anywhere. Amounts start hidden even for those who may see them: revealing is the deliberate act. |
| **Reports** | Product history, stock export to Excel, and the donation certificate a hospital signs. |

Assembling a kit, refused because one component has expired stock here. The
count and the date are on the offending row; the column is rendered on every row
so nothing shifts under a thumb already on the next line:

![The kit conference, refusing to assemble](docs/images/kit-expired-block.png)

The stock list, which separates a balance that was counted from one that was
inherited from a box that travelled:

![The stock list](docs/images/stock.png)

## Running it locally

Needs Docker and [mise](https://mise.jdx.dev) (or asdf — the versions are in
`.tool-versions`).

```bash
docker compose up -d          # Postgres on 5433
mix setup                     # deps, database, catalog seeds, assets
mix dev.seeds                 # the demo scenario: stock, invoices, missions
mix phx.server
```

Then open http://localhost:4000 and log in as `admin@exemplo.org` with the
password `mix dev.seeds` prints.

One account, deliberately. Creating the others is the first thing an
administrator does on a fresh install, and it is a flow worth walking rather
than seeding around — the temporary password, the forced change on first login,
and the role that decides whether prices are visible at all. `/admin/users` is
where it happens.

| Role | Sees |
|---|---|
| admin | everything, plus who gets an account |
| manager | the whole operation, money included |
| marketing | the marketing stock and nothing else — takes it in, sells it, sees its prices |
| logistics | boxes, counts, load-outs, returns. No prices, anywhere |
| auditor | everything, money and ledger included. Writes nothing |

`mix precommit` runs what CI runs: format, unused deps, advisories, warnings as
errors, Credo (strict), Sobelow, and the tests.

## Tests

830 of them, including the ledger invariants and the NF-e parser, which are the
two highest-value targets in the codebase.

```bash
mix test
```

The parser is checked against the two sample invoices in `priv/samples/` —
fictional companies, genuine NF-e 4.00 structure, one with a `rastro` group and
one with lot data only in free text.

## Deploying the demo

Free, and no card: one web service and one Postgres on
[Render](https://render.com)'s free plan, both described in
[`render.yaml`](render.yaml). Push to GitHub, then **New → Blueprint** and pick
the repository — Render reads the file, asks for the four `ORGANIZATION_*`
values, and builds. There is no separate step to migrate or to load the data:
`rel/entrypoint.sh` migrates, seeds a database that has nobody in it yet, and
then serves.

It deploys from `main`, and only when CI is green — `autoDeployTrigger:
checksPass`, so a red commit never reaches the demo. Turn it off on the day of a
presentation: a redeploy compiles Elixir and takes minutes, and the free plan
runs one instance.

Two facts about the free plan, easier to accept than to discover during a
presentation: the service **sleeps** after 15 minutes idle and takes about a
minute to wake, and the free database is **deleted 30 days after it is
created**. [`docs/deploy-render.md`](docs/deploy-render.md) has the full runbook,
including how to keep full certificate verification on the database connection
and how to load data by hand from a laptop.

The `Dockerfile` is the actual deployment contract — pinned to the same Elixir
1.20.2 and Erlang 29.0.4 the tests run on, published for amd64 and arm64. So
anything that runs a container runs this: Fly.io, Koyeb, a VPS with Compose, an
ARM instance on Oracle Cloud. Only `render.yaml` and the
`RENDER_EXTERNAL_HOSTNAME` fallback are Render-specific.

And because the release builds its own assets, the whole image is testable
before it is deployed — which is how the above was verified rather than hoped:

```bash
docker build -t estoque-os .

docker run --rm --network host \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e DATABASE_URL="ecto://postgres:postgres@localhost:5433/estoque_os_docker" \
  -e DATABASE_SSL=false -e SEED_ON_EMPTY=true \
  -e PHX_HOST=localhost -e PORT=4021 \
  estoque-os
```

### Configuration

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | — | required |
| `SECRET_KEY_BASE` | — | required; `mix phx.gen.secret` |
| `PHX_HOST` | `RENDER_EXTERNAL_HOSTNAME`, then `example.com` | the public hostname |
| `POOL_SIZE` | `2` | what a free-plan database allows |
| `SEED_ON_EMPTY` | unset | load the catalog and demo on a first boot into an empty database |
| `EMAIL_ENABLED` | `false` | see below |
| `ORGANIZATION_DOCUMENT` | placeholder | printed on donation certificates |
| `ORGANIZATION_ADDRESS` / `_CONTACT` / `_NAME` | placeholder | same |
| `DATABASE_CA_CERT_FILE` | — | when the database sits behind a private CA |
| `DATABASE_SSL_VERIFY` | `peer` | `ca` skips only the hostname check, `none` skips both and shouts on boot |
| `DATABASE_SSL` | `true` | `false` only to smoke-test the image against a local Postgres |

**Email is off by default, and production leaves it off.** Accounts are handed
out by an administrator with a temporary password, so nothing about getting in
depends on a message arriving — which means a deployment with no mailer is a
supported deployment rather than a broken one, and the demo needs no sending
domain and no outbound provider. The flows that can only work by email — the
magic link, "esqueci minha senha", confirming a changed address — are grouped
behind one gate and answer with an explanation instead of a form that leads
nowhere. Turning them back on is `EMAIL_ENABLED=true` plus a Swoosh adapter;
they are intact and tested, not deleted.

## Layout

```
lib/estoque_os/          contexts: Accounts, Catalog, Inventory, Invoices,
                         Kits, Missions, Outbound, Receiving, Reports
lib/estoque_os_web/live/ one directory per screen
priv/repo/migrations/    seven, one per context
priv/samples/            the fiscal documents and spreadsheets the seeds and
                         the parser tests read
Dockerfile               the deployment contract: pinned Elixir and Erlang,
                         assets built inside the release, amd64 and arm64
render.yaml              the free-plan deployment, as a file
docs/SPEC.md             the source of truth for domain and design decisions
docs/deploy-render.md    the deployment runbook
docs/production-acceptance.html
                         fifty acceptance tests to run against a deployment,
                         with steps and acceptance criteria
PRODUCT.md               who this is for and what it must not become
```

Before showing a deployment to anyone, run
[`docs/production-acceptance.html`](docs/production-acceptance.html) — fifty
tests in the order they have to happen, each with what to do and what must be
true afterwards. Three of them exist because the failure is invisible from the
app: the donation certificate's letterhead comes from the environment, the email
flows are meant to be off, and the free tier sleeps after thirty days without a
deploy.

## A note on the sample data

The two NF-e, the correction letter and both spreadsheets came from the real
operation. Because this repository is public, every party in them was
replaced — companies, registrations, addresses, contacts, the embedded signing
certificates — and the history was rewritten so it never contained the
originals. What survives is the shape: the tax groups, the two different places
a supplier hides a lot number, the missing NCMs, the sector typed both
`CRASHBOX` and `CRASHBIX`, and the spreadsheet range reference pasted into the
middle of a word. That mess is the specification.
