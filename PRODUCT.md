# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

**A coordenadora de suprimentos da Operação Sorriso do Brasil.** Buys from
~17 suppliers, receives NF-e (PDF + XML), forwards goods to a third-party
logistics operator, and is accountable for what leaves and comes back from each
week-long surgical mission. Her words for the current situation: *"estou cega no
estoque"*. Today the job costs her more than a week of manual spreadsheet work
per mission, most of it dividing invoice prices by pack size by hand.

**The logistics operator (currently STRALOG)** also uses the system. They store
goods in identified boxes (`AN01`, `JP04`, `NS03`) and today return a
spreadsheet with description, quantity and box — never prices. Because they are
a partner outside the ONG's context, screens they touch must be understandable
without training and without institutional vocabulary.

Roles in the system: `admin`, `operator`, `viewer`. Around two concurrent users.

## Product Purpose

Replace a fully manual Excel workflow with a stock system that stays auditable
across missions. Success is the supply coordinator importing a real invoice and getting unit
prices in seconds instead of a week, and being able to answer "what do we have,
where, in what state, and who moved it" at any moment — including for a
Brazilian auditor.

Current destination: a **prototype to present to the ONG**. It must demonstrate
the value convincingly in a demo before becoming the operation's real system, so
clarity of the proposition ranks alongside operational correctness. Real
operational constraints (audit trail, controlled substances, lot traceability)
are already honored and must not be traded away for demo polish.

## Positioning

Three mechanisms a neighboring inventory product does not offer this operation:

- **Unit price derived from the invoice.** NF-e prices are per commercial unit
  (a box of N pieces); donations and mission usage are in individual units. The
  system reads the pack size from the invoice line, asks for confirmation once,
  and never asks again — this is the week of manual work it removes.
- **Presumed vs verified balances.** Boxes are movable containers that travel
  whole without a recount. The system tracks `last_verified_at` and says out
  loud when a number is presumed rather than counted, instead of pretending
  every balance is equally true.
- **Partial counts as a first-class flow.** A full inventory is never a
  precondition for anything, because in a mission storage room it is not
  possible. The mini-audit answers "which box do I open first" and records what
  was actually counted, leaving uncounted lines untouched.

A previous SAP attempt failed on supplier naming chaos ("agulha" vs "Sterecam",
"bandagem" typed as "bagagem"). Matching by GTIN first, then supplier code, then
ranked description suggestions, is the answer to the thing that killed it.

## Operating Context

- **Missions** are week-long surgical trips (cleft lip/palate) to remote
  Brazilian cities. Usually the *entire* stock leaves the warehouse for the
  mission; only dead files and empty boxes stay behind.
- **Between missions** stock in movement is accounted as *estoque em trânsito*.
  Stock sometimes goes straight from one mission to the next without passing
  through the logistics operator.
- **Returns are chaotic.** Items come back in different boxes than they left in,
  and part of the load simply does not come back — it was used.
- **Storage rooms are precarious.** Full audits are impossible; partial counts
  are the reality.
- **Documents:** NF-e XML (layout 4.00) and DANFE PDF from suppliers, CC-e
  correction letters, the OSI standard supply table per mission size, kit
  spreadsheets, and — at mission end — *termo de doação* and *termo de
  recebimento* signed with hospitals.
- **Controlled substances** (anesthetics, Portaria 344) ride in the same stock.
  Lot traceability is mandatory in practice.
- **Audits** are performed by Brazilian auditors. There is no OSI reporting
  requirement; a clean audit trail is what is valued.

## Capabilities and Constraints

Built and working (SPEC phases 1–3): NF-e 4.00 import with match-and-confirm,
append-only ledger with derived balances and FEFO, Excel export/count import,
receiving conference with divergence report, box movement and transit,
prioritized mini-audit, load-out, kit assembly/consumption, manual issue,
mission returns with re-boxing, donations with printable certificates, and an
auditor report.

Constraints that future work must preserve:

- **Append-only ledger.** No editable balance anywhere; every change is a
  transaction, adjustments carry a reason code, nothing is hard-deleted.
- **Money as Decimal; unit cost may be null.** A donation with no informed value
  is recorded as unknown, never as R$ 0,01 — a symbolic cent poisons average
  cost and stock value.
- **All code, schema and identifiers in English; all user-facing text in
  Brazilian Portuguese through Gettext** (`pt_BR` default). No hardcoded
  Portuguese in code, no English leaking into the UI.
- **Online-first.** No offline sync. The escape hatch for bad connectivity is
  Excel export/import, which produces transactions and never direct balance
  writes.
- Brazil-specific invoice logic stays behind an importer behaviour so other
  countries can be added later. i18n from day one.
- Barcode *hardware* is out of scope, but GTIN inputs must work naturally with a
  keyboard-wedge scanner (types digits + Enter).

Explicitly out of scope: per-patient/per-surgery consumption tracking (keep
transaction destinations generic so it can be added later), offline sync, formal
purchase-order lifecycle, supplier invoicing/AP, budget codes.

## Brand Commitments

- Name: **Operação Sorriso do Brasil**, CNPJ 00.000.000/0000-00. It appears on
  the printed certificates as letterhead.
- The organization **has an official visual identity (logo, colors, typography),
  but the files are not available yet.** This is a binding constraint with an
  open decision attached: no color, mark or typeface may be presented as the
  ONG's official identity until the real assets arrive. Any visual world chosen
  before then is provisional and must be swappable.
- Language of the interface is Brazilian Portuguese, in the operation's own
  vocabulary: *derrubada de carga*, *estoque em trânsito*, *termo de doação*,
  *lote*, *validade*, *caixa*.

## Evidence on Hand

Real, in `samples/`:

- Two genuine NF-e XMLs — MedSul (7 items, structured `rastro` group) and
  Cirúrgica Atlântica (4 items, lot data only in `infAdProd` free text) — with
  their DANFEs.
- A real CC-e (correction letter) for the MedSul invoice.
- `Tabela_padrão_-_suprimentos_médicos_Missão_de_4_mesas.xlsx`: the OSI standard
  supply table, 326 lines, with its real messiness (40 without NCM, 3 whose NCM
  is not an NCM, a unit column reading "OK", a sector typed both CRASHBOX and
  CRASHBIX).
- `Kits.xlsx`: the five mission kits (Paciente, Anestesia, Enfermagem, Pré e
  Pós, Recuperação) with 199 components in free text.

Not on hand, and not to be fabricated: testimonials, customer logos, usage
metrics, mission photography, pricing, hospital names beyond those in the sample
documents, and any claim about how many missions or patients the system has
served.

## Product Principles

1. **Say what is true, including when the truth is "we do not know."** Presumed
   balances, uncounted lines, and unknown values are labelled as such rather
   than rounded into false precision.
2. **The ledger is the record; screens are windows onto it.** No screen may
   write a balance, hide an adjustment, or show a number the ledger cannot
   justify.
3. **Partial is the normal case.** Partial counts, partial returns, partial
   resolution of invoice lines — every flow must complete honestly with
   incomplete information.
4. **The system learns the vocabulary once.** Resolving a supplier's wording,
   GTIN or pack size teaches the catalog, so the same work is never done twice.
5. **Speed where the pain is.** The unit price, the load-out, and the count are
   the operations that cost the coordinator her week; they get the fewest clicks
   and the clearest defaults.

## Accessibility & Inclusion

- Used on notebooks and phones inside warehouses and hospital storage rooms:
  mobile-friendly layout is a functional requirement, not a nicety.
- The logistics operator is outside the ONG's context; their screens must be
  usable without training and without internal jargon.
- No formal accessibility standard has been established with the ONG yet — an
  open decision. Baseline expectations already honored in code: labelled
  controls, keyboard-reachable actions, and status conveyed by text and not by
  color alone.
