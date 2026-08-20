# Inventory System — Operação Sorriso (Operation Smile Brazil)

## 1. Purpose

Build an inventory management system for **Operação Sorriso do Brasil** (Operation
Smile Brazil, CNPJ 22.333.444/0001-81), a non-profit that runs week-long surgical
missions (cleft lip/palate) in remote Brazilian cities. The system replaces a
fully manual Excel-based workflow that costs the supply coordinator more
than a week of manual work per mission and leaves the stock effectively
unauditable ("I am blind in the stock").

Initial deployment: Brazil. Design must not block future international use
(i18n from day 1, Brazil-specific import logic isolated behind a behaviour).

## 2. Tech stack and conventions

- **Elixir + Phoenix LiveView**, PostgreSQL, Tailwind. Ecto for persistence.
- **All code, schemas, tables, columns, modules, functions in English.**
- **All user-facing content in Brazilian Portuguese** via Gettext, default
  locale `pt_BR`. Product names, descriptions, reason labels, generated
  documents: Portuguese (data or .po files). Never hardcode Portuguese in code.
- Mobile-friendly UI (used on notebooks and phones inside warehouses/hospitals).
- ~2 concurrent users. Simple email+password auth (phx.gen.auth) with roles:
  `admin`, `operator`, `viewer`.
- Online-first. NO offline sync in MVP. The escape hatch for bad connectivity
  is Excel export/import (see §7).
- Brazil-specific NF-e import lives in `Invoices.Importers.NFe` behind a
  generic importer behaviour, so other countries can add importers later.

## 3. Domain context (how the operation works today)

1. OSI (Operation Smile International) provides a standard supply table for a
   mission (e.g. "4 surgical tables" — see `priv/samples/Tabela_padrão_*.xlsx`,
   sheet "Tabela padrão - Suprimentos méd": columns DESCRIÇÃO, QUANTIDADE,
   OBSERVAÇÃO, NCM, UNIDADE DE MEDIDA, Classificação, SETOR).
2. The supply coordinator buys from ~17 suppliers (see "Resumo" sheet in the same file).
   Suppliers send **NF-e**: PDF (DANFE) + XML.
3. She forwards PDF+XML to a third-party logistics operator (current: STRALOG),
   who stores goods in **identified boxes** (codes like `AN01`, `JP04`, `NS03`)
   and returns a spreadsheet with description, quantity and box — **no prices**.
4. Pain #1: the NF-e prices are per commercial unit (often a BOX of N pieces).
   Donations to hospitals and mission usage are in **individual units**, so she
   manually divides prices item by item across invoices — over a week of work,
   error-prone, "never reconciles".
5. "Derrubada de carga" = load-out request: the full load leaves the warehouse
   to a mission (usually the ENTIRE stock goes; only dead files and empty boxes
   remain). Between missions, stock in movement is accounted as
   **estoque em trânsito** (stock in transit).
6. After a mission, returns are chaotic: items come back in DIFFERENT boxes
   than they left in. Sometimes stock goes **directly from one mission to the
   next** without passing through the logistics operator for verification.
7. Mission storage rooms are often precarious; full audits when boxes are
   stored are impossible — partial counts are the reality.
8. Same product coexists in stock with multiple lots/expiry dates.
9. Items also enter WITHOUT an invoice: donations from hospitals and items
   brought by volunteers. Today these are entered manually with description,
   lot and expiry, and value empty or R$ 0,01.
10. Controlled substances (anesthetics, Portaria 344) pass through this stock;
    entry flow is the same, but lot traceability is mandatory in practice.
11. End of mission: leftover items may be donated to hospitals. A **termo de
    doação** (donation certificate) and **termo de recebimento** (receipt
    certificate) are required documents.
12. Audits are done by Brazilian auditors (no OSI reporting requirement).
    A clean audit trail and ready-made auditor reports are highly valued.
13. Naming chaos: suppliers use different names for the same product
    ("agulha" vs "Sterecam"), and warehouse staff typing by hand introduce
    typos ("bandagem" → "bagagem"). This killed a previous SAP attempt.
14. Future desire (OUT of MVP): per-patient / per-surgery consumption. Model
    transaction destinations generically so this can be added later without
    refactoring.

## 4. Core design decisions (non-negotiable)

### 4.1 Ledger model — stock is an append-only journal

- No editable `quantity_on_hand` column anywhere.
- `transactions` (type, occurred_at, source_location, destination_location,
  reason_code, actor, linked document) contain `transaction_entries`
  (lot, box, signed quantity, unit_cost snapshot).
- Balances are ALWAYS derived by summing entries. Add a materialized
  snapshot/rollup table for performance, refreshed transactionally — it is a
  cache, never a source of truth.
- Adjustments are transactions with mandatory reason codes
  (expiry, damage, loss, count_correction, ...). Full audit trail.

### 4.2 Lot-level tracking

- `lots`: product_id, lot_number, manufactured_on, expires_on. Every
  transaction entry references a lot (create an "unknown lot" only as a last
  resort, flagged).
- FEFO (first-expiry-first-out) is the default picking suggestion for
  load-outs, kit consumption and donation lists.

### 4.3 Locations and boxes

- `locations` is a tree: warehouse(s) → hospital/mission sites → a special
  `transit` location type (matches the accounting concept of estoque em
  trânsito). Transfers are transactions between locations.
- `boxes` are first-class movable containers (code like AN01) that live at a
  location and can move between locations as a whole. Moving a box moves its
  **presumed contents** without item-level recount.
- Each box has `last_verified_at`. Balances therefore carry a data-quality
  dimension: *verified on date X* vs *presumed since last movement*. Surface
  this honestly in the UI.
- Mission→mission direct transfers are legal and cheap: move boxes, no forced
  recount. Divergences are fixed at the NEXT count wherever it happens.
- A box reaches a mission site or transit **only through the load-out**, never
  by editing its location (decided 2026-08-10 with the ONG). Arriving at one of
  those is the moment the movement acquires a reason —
  which trip it belongs to — and the load-out is the only flow that asks. The
  guarantee above is untouched: the load-out forces no recount either. Moves
  between warehouses stay one click, because between missions they happen dozens
  of times. Enforced in `Locations.move_box/3`, not only in the UI.

### 4.4 Partial, prioritized cycle counts

- Never require a full inventory as a precondition for anything.
- A guided "mini-audit" flow suggests which boxes to count first, prioritized
  by: (1) controlled substances, (2) near expiry, (3) stock value,
  (4) oldest `last_verified_at`. Counting a box records adjustments (with
  reasons) and refreshes `last_verified_at`.

### 4.5 Products, groups and identification

- `products`: canonical name (pt-BR), stock unit, conversion notes, NCM,
  optional per-product min-stock and expiry-alert overrides, controlled flag.
- `product_groups` with synonyms (e.g. group "Agulhas") for search and for
  mapping divergent supplier nomenclature.
- `product_identifiers`: many GTINs (cEAN) and supplier codes (cProd per
  supplier CNPJ) per product. **GTIN is the primary matcher** on import;
  NCM is a secondary hint; description matching is last.
- Units of measure: purchases arrive in a commercial unit (CX, PT, FR, PC,
  UND...); stock is kept in individual units. `conversion_factor` per
  product+supplier-unit ("1 CX = 250 UN"), asked ONCE on first import (with a
  suggestion parsed from the description, see §6) and reused afterwards.
- Sanity check on import: if the derived unit cost diverges wildly from the
  product's historical unit cost (e.g. 100x — the classic total-vs-unit swap),
  raise a blocking warning for human confirmation.

### 4.6 Kits (BOM)

- `kits` + `kit_items`: named kits (Kit Paciente, Anestesia, Enfermagem,
  Pré e Pós, Recuperação — seed from `priv/samples/Kits.xlsx`, one sheet per kit,
  columns: item description, quantity).
- A kit is a product too: `products.kit_id` links a kit to the catalog
  product that represents it in stock. Every kit gets one, created
  alongside it — a kit is never without a product, the same way a
  `kit_item` is never without a description.
- Assembling is a conversion, decided by `Kits.assemble/3`: the components
  are drawn via FEFO and leave stock for good (`kit_assembly` transaction),
  and a new lot of the kit's own product appears in the box instead, sized
  to however many whole kits the components on hand actually cover. A kit
  is never partially built.
- `kit_lot_provenances` (kit_lot_id, component_lot_id, quantity) is the
  many-to-many that keeps a recall traceable without the kit needing to be
  the components: given a recalled component lot, which kit lots it went
  into, and from there where those lots are now — the same
  `position_balances` query any other product's recall already uses.
- From the moment a kit is assembled, writing it off is writing off a
  product: the same "Dar baixa" (issue) and FEFO picking that handle any
  other product handle a kit, with no kit-specific code in that path.

### 4.7 Entries without invoice (donations in)

- Transaction type `donation_in` with **nullable unit cost** (NEVER 0.01 —
  a symbolic cent poisons average-cost and stock-value reports). Reports must
  handle null cost as "market value not informed".

### 4.8 Document generation

- Generate PDF **termo de doação** and **termo de recebimento** from a
  selected list of items (product, lot, expiry, quantity, unit/total value
  when known), with ONG letterhead data. Keep templates in Portuguese,
  structured for future localization.

### 4.9 Alerts and dashboard

- Landing dashboard: items near expiry (global default window, per-product
  override), items at/below min stock (global default, per-product override),
  boxes with stale verification, recent activity.
- FEFO-driven "donate before expiry" suggestion list at mission end.

## 5. What is OUT of the MVP

- Per-patient/per-surgery tracking (keep destinations generic).
- Offline-first sync.
- Formal purchase-order lifecycle, supplier invoicing/AP, budget codes.
- Barcode HARDWARE integration — but design entry fields so a keyboard-wedge
  barcode scanner (types digits + Enter) works naturally on GTIN search
  inputs from day 1.

## 6. NF-e import (the heart of the system)

NF-e layout 4.00 is standardized nationally — **one parser**, not one per
supplier. Store the raw XML and the 44-digit access key (unique constraint).
Sample documents in `priv/samples/` (analyzed; parties anonymized):

- `35260411222333000424550010009770981447856989-nfe.xml` — **MedSul**.
  All 7 items have `cEAN` (real GTINs), all have the structured `rastro`
  group (`nLote`, `qLote`, `dFab`, `dVal`); medications also carry
  `med/cProdANVISA`. Units: CX, FR, UND. Descriptions embed pack size
  ("25 FRASCO AMPOLA", "C/100", "100AMP").
- `35260455666777000181550040019851671590327796-nfe.xml` — **Cirúrgica
  Atlântica**. All items have `cEAN`. NO `rastro`; lot/expiry live in
  `infAdProd` free text with a stable pattern:
  `| Lote:<X>, Validade:<dd/mm/yy>, Quantidade:<N>`. Units: PT, PC.
  Pack size embedded in description ("PT/50").
- `1101103526041122233300042455001000977098144785698901-cce.xml` — a CC-e
  (correction letter event). MVP: just store/attach it to the invoice by
  access key; no field-level reprocessing.

Extraction strategy, in order:
1. `rastro` group (structured lot/expiry) when present.
2. Regex on `infAdProd` (pattern above; tolerate 2- and 4-digit years and
   line-wrapped values).
3. If neither: import the item flagged `needs_review`; the receiving/confirm
   screen asks for lot/expiry manually. (An optional AI-assisted extraction
   can be added later — not in MVP.)

Conversion factor suggestion: parse pack size from `xProd` description
(`C/100`, `PT/50`, `CX 250`, `25 FRASCO`, `100AMP`, `10 FRASCOS` ...) as a
SUGGESTION requiring one-time human confirmation per product+unit.

Import flow (LiveView):
upload XML → parse → match items (GTIN → supplier cProd → NCM+description
suggestions) → resolve unmatched (create product or attach to existing/group)
→ confirm conversion factors → post `purchase_in` transactions (lots created,
unit costs = vUnCom / conversion_factor) → optionally assign boxes now or in
a later receiving step.

Receiving/conference (phase 2): check received items against the invoice,
report divergences ("expected 30, counted 27"), assign box per item, repeat
count option, discrepancy report for the supplier.

## 7. Excel import/export — the safety valve

- Export full stock (product, group, lot, expiry, box, location, quantity,
  unit cost, total) to XLSX at any time.
- Import an inventory spreadsheet (initial migration from the current Excel
  world, or post-mission catch-up when connectivity failed). Import produces
  TRANSACTIONS (type `inventory_import` / `count_correction`), never direct
  balance writes. Validate and report row-level errors.

## 8. Schema sketch (guide, not a straitjacket)

- `products` (name, product_group_id, ncm, stock_unit, controlled boolean,
  min_stock_override, expiry_alert_days_override, active)
- `product_groups` (name) + `product_group_synonyms` (name)
- `product_identifiers` (product_id, kind: gtin|supplier_code, value,
  supplier_id nullable; unique per kind+value+supplier)
- `unit_conversions` (product_id, from_unit, factor)  # 1 CX = 250 UN
- `lots` (product_id, lot_number, manufactured_on, expires_on)
- `locations` (parent_id, name, kind: warehouse|mission_site|transit|other)
- `boxes` (code, location_id, last_verified_at, active)
- `suppliers` (cnpj, legal_name, trade_name, contact fields)
- `invoices` (supplier_id, access_key unique, number, series, issued_on,
  total, raw_xml, status) + `invoice_items` (parsed line data, matched
  product_id, lot data, conversion applied, needs_review)
- `transactions` (type: purchase_in|donation_in|transfer|load_out|return_in|
  kit_assembly|kit_consumption|manual_out|adjustment|inventory_import,
  occurred_at, source_location_id, destination_location_id, reason_code,
  user_id, invoice_id nullable, notes)
- `transaction_entries` (transaction_id, lot_id, box_id nullable,
  quantity signed, unit_cost nullable)
- `kits` (name, description) + `kit_items` (kit_id, product_id, quantity)
- `products.kit_id` (nullable, unique): the product that stands in for the
  kit in stock
- `kit_lot_provenances` (kit_lot_id, component_lot_id, quantity)
- `stock_snapshots` (materialized rollup: lot_id, box_id, location_id,
  quantity) — cache only
- `users` (phx.gen.auth) + role

## 9. MVP delivery phases

**Phase 1 — kill pain #1 (unit pricing + catalog):**
products/groups/identifiers/conversions, suppliers, NF-e XML import with the
full match-and-confirm flow, lots, ledger core, Excel export/import, unit-cost
sanity alert, seed catalog from `Tabela_padrão_*.xlsx` and kits from
`Kits.xlsx`. Deliverable: the supply coordinator imports a real invoice and gets unit prices
in seconds.

**Phase 2 — receiving + visibility:**
box assignment/receiving conference against invoice, divergence report,
dashboard (expiry, min stock, stale boxes), prioritized mini-audit flow,
locations/transit, box transfers (incl. mission→mission).

**Phase 3 — outbound:**
load-out (derrubada) with FEFO, kit assembly/consumption, manual issue with
group search, returns with guided recount and re-boxing, donation lists with
termo de doação / termo de recebimento PDFs, auditor report.

## 10. Quality bar

- Tests: NF-e parser MUST be tested against both XMLs in `priv/samples/`
  (assert item counts, GTINs, lots, expiry dates, unit values, and the
  Atlântica infAdProd regex). Ledger invariants tested (balance = sum of
  entries; no negative stock without explicit adjustment; snapshot equals
  ledger).
- Money as Decimal (never float). Dates as Date; timestamps UTC.
- Every destructive action is a new transaction, nothing is deleted.
- Seeds: locations (Escritório SP, Estoque Principal warehouse, Trânsito), kits,
  product catalog from the standard table.
