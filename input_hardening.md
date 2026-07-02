# Dataset Input Hardening — Detailed Spec

Five workstreams that attack the two real data-quality failure modes:

- **Problem A — false "No match":** a real Nestlé product scans as unknown
  (measured: only ~53% of brand slugs matched an OFF tag at 601 brands; the
  dataset is now 854 brands / 34,422 barcodes as of `2026.07.02.0217`, so
  re-measure before and after each workstream).
- **Problem B — false positives:** a barcode in our table maps to Nestlé when
  the physical product is made by someone else (US KitKat → Hershey under
  license; US Crunch/Butterfinger → sold to Ferrero in 2018; US "Smarties" →
  an unrelated company). These are the trust-killers.

Non-negotiable ground rules for every workstream:

1. **License-clean sources only.** The bundled SQLite is redistributed under
   ODbL. Ingest only ODbL (OFF family), CC0 (Wikidata), or equivalently open
   data. No commercial UPC databases, no scraping non-open sources, no
   LLM-generated "facts."
2. **Provenance on every row.** The `source` column discipline extends to all
   new tables (`aliases`, `exceptions`, `prefixes`).
3. **Negative controls grow with coverage.** Every workstream adds anchors to
   `test_spike.py` proving known non-Nestlé products still return no match.
   Coverage gains that break false-positive controls are net losses.
4. **Additive-only schema changes.** Self-update ships new datasets to old app
   binaries. Old queries (`SELECT b.brand_name, b.parent, b.is_target …`) must
   keep working: new columns and new tables only; never rename, repurpose, or
   drop existing columns. (`JSONDecoder` ignores unknown manifest keys, so
   optional manifest fields are also safe.)
5. **Free tier.** Everything runs inside the existing daily GitHub Actions job
   (public repo, ~14 GB disk, 6 h limit) with stdlib-only Python.

Recommended order: **W1 → W2 → W3 → W4**, with **W5** any time. W3's co-brand
rules can start before W2 (the API path already fetches `brands_tags`), but its
region evidence needs W2.

---

## W1 — Brand-tag reconciliation against OFF's real vocabulary

**Goal:** convert normalization misses (our slug ≠ OFF's tag: `kit-kat` vs
`kitkat`) from silent coverage loss into an explicit, shrinking review queue.

**Why:** a large share of the ~47% zero-hit slugs are brands OFF *does* have
under a spelling our normalizer doesn't produce. This is the cheapest coverage
win available.

### Sources & licensing

- OFF brands facet — the complete list of real `brands_tags` values with
  product counts: `https://world.openfoodfacts.org/brands.json` (ODbL).
  Sibling facets exist per database (`world.openpetfoodfacts.org/brands.json`,
  etc.); fetch all four. Verify exact endpoints/pagination at implementation
  time; cache the downloaded facet in `out/`.

### Design

New pipeline step `reconcile_brands.py`, run after `build_brands.py`:

1. **Candidate generation** (pure function, unit-testable): for each brand
   slug, emit alias candidates —
   - hyphen-collapsed (`kit-kat` → `kitkat`) and the reverse split points;
   - apostrophe/possessive forms (`stouffer-s` ↔ `stouffers`);
   - `nestle-` prefixed variant (`crunch` → `nestle-crunch`);
   - `&`/`and` swaps, corporate-suffix strips (`-co`, `-inc`, `-gmbh`, `-sa`,
     `-ag`, `-ltd`);
   - accent-stripped forms are already handled by `common.off_slug`.
2. **Exact matching only in the automated path:** a candidate counts as a hit
   iff it appears verbatim in the facet vocabulary. No auto-accepted fuzzy
   matches.
3. **Fuzzy suggestions go to humans:** `difflib.get_close_matches` (stdlib)
   with a high cutoff produces a *review report* (`out/alias_review.txt`),
   never dataset rows. Approved matches are committed to a curated
   **`data-pipeline/aliases.csv`** (`alias_slug,canonical_slug,note`) that the
   pipeline merges — same pattern as the existing `CURATED` list, but data,
   not code.
4. **Emission:** accepted aliases become additional `brands` rows (alias slug,
   canonical display name) exactly like curated variants today, so
   `build_barcodes.py` and the app need **zero changes**.

### Guardrails & tests

- **Collision defense:** alias generation must never produce a slug belonging
  to another company. Maintain a `KNOWN_NON_TARGET_TAGS` denylist (seeded:
  `hershey-s`, `coca-cola`, `mondelez`, `mars`, `ferrero`, `smarties` per the
  W3 note below…) and fail the pipeline if any generated alias lands in it
  without an explicit curated override.
- Unit tests in `test_parsing.py` for candidate generation (each rule, and the
  denylist trip).
- Report the match rate (`slugs with ≥1 facet hit / total`) in the workflow
  summary next to the counts; this is the workstream's success metric.
- The shrink guard (`check_counts.py`) already tolerates growth; no change.

### Risks

- Generic-word brands (`crunch`, `smarties`, `aero`) collide across companies
  and regions. The denylist plus W3's exceptions table are the containment;
  when in doubt an alias stays in the review queue.

**Effort:** ~1 day + ongoing light curation. **Dependencies:** none.

---

## W2 — Migrate the barcode side to the OFF bulk dump

**Goal:** complete coverage of what OFF actually knows (no 10k search-window
cap, no search-index gaps) plus the evidence fields Problem B needs
(`countries_tags`, owner/co-brand data).

**Why:** `FINDINGS.md` already names the dump as the production source. The
Search-a-licious path samples; the dump enumerates. It also carries per-product
fields the search path doesn't return today.

### Sources & licensing

- OFF full CSV export (tab-separated, gzipped):
  `https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz`
  (~1 GB compressed, ~9–11 GB raw, ~3.5 M rows; ODbL).
- Sibling dumps for OPFF/OBF/OPF from their `static.*` hosts (small, tens of
  MB) — verify exact URLs at implementation time; keep the classic API as
  fallback for any sibling without a usable dump.
- **Not** the JSONL (too big to stream comfortably in the job window) and
  **not** the Parquet export (needs `pyarrow` → violates the no-pip rule).

### Design

New `build_barcodes_dump.py` (or `build_barcodes.py --mode dump`, keeping
`--mode api` alive as the degradation path):

1. **Stream, never store raw:** `urllib` fetch piped through `gzip` →
   `csv.reader(delimiter="\t")` with `csv.field_size_limit` raised. Only
   matched rows are kept in memory (~10⁴–10⁵ rows, trivial).
2. **Row filter** (pure function, unit-testable with synthetic TSV): parse
   `brands_tags`; intersect with the slug set (O(1) set lookup); on match,
   capture `code`, matched slug(s), *all* `brands_tags` (co-brand evidence for
   W3), `countries_tags`, and the owner field. Note: verify the exact owner
   column name in the CSV export at implementation time (`owner` vs
   `brand_owner`); if absent, W3 falls back to co-brand + prefix evidence.
3. **De-dup and provenance:** same barcode-first-wins merge as today; source
   values `off-dump`, `opff-dump`, … so provenance distinguishes dump-derived
   rows from API-derived ones.
4. **Resilience:** dump fetch/parse failure → log a workflow warning and fall
   back to `--mode api` so the daily release still ships. The shrink guard
   remains the backstop against a silently truncated dump.
5. **Runtime budget:** streaming ~9 GB of text is roughly 10–25 min on a
   runner — well inside the 6 h limit; disk use ~1 GB (compressed stream
   only).

### Guardrails & tests

- Unit tests for the row filter: matching row kept with evidence fields;
  non-matching skipped; malformed row skipped without aborting; co-brand and
  countries fields preserved verbatim.
- `test_spike.py` anchors unchanged and must still pass; expect a barcode
  count jump — after numbers stabilize for a week, raise `MIN_BARCODES`
  accordingly so regressions are caught at the new level.
- Compare dump-mode output against API-mode output once in CI (one-off
  validation step: dump ⊇ api minus known drift) before switching the default.

### Risks

- OFF occasionally publishes late or truncated dumps → covered by fallback +
  shrink guard.
- Field/format drift in the CSV header → the row filter must locate columns by
  header name, not index, and fail loudly if a required column disappears.

**Effort:** 1–2 days. **Dependencies:** none (W1 improves its yield).

---

## W3 — Licensing & regional exceptions (kill the false positives)

**Goal:** a barcode that matches a target brand slug but is *made by someone
else* must never produce a bare "Nestlé — avoid." Instead: exclude it, or
better, tell the truth with more precision than the user expected
("KitKat — made under license by **Hershey** in the US").

**Why:** this is the credibility failure mode. It also finally gives the
reserved `.notTarget` verdict a legitimate, evidence-backed use.

### Evidence (all license-clean, mostly unlocked by W2)

| Evidence | Example for US KitKat |
|---|---|
| Co-brand tags | `brands_tags: [kitkat, hershey-s]` |
| Owner field (where present) | `The Hershey Company` |
| Country scope | `countries_tags: [en:united-states]` |
| GS1/UPC prefix | Hershey's US prefix `034000` |

### Curated rules file

`data-pipeline/exceptions.csv` (checked in, reviewed like code):

```
brand_slug,scope_type,scope_value,actual_maker,action,note,source_url
kitkat,co_brand,hershey-s,Hershey,reattribute,"US KitKat made under license by Hershey since 1970",<citation>
crunch,country,en:united-states,Ferrero,reattribute,"US confectionery (Crunch/Butterfinger/Baby Ruth) sold to Ferrero 2018",<citation>
smarties,country,en:united-states,Smarties Candy Company,exclude,"unrelated US brand; Nestlé Smarties not sold in US",<citation>
```

`scope_type ∈ {co_brand, country, prefix}`; `action ∈ {exclude, reattribute}`.
Every row requires a citation URL. Seed with the three above; grow via the
review queue (W1) and user reports.

### Pipeline design

- Apply rules during barcode collection using the captured evidence:
  - `co_brand`: the row's `brands_tags` contain the scope value;
  - `country`: the row's `countries_tags` match (apply only when the product's
    country evidence is unambiguous — a product listed in many countries
    doesn't trigger a single-country rule);
  - `prefix`: the barcode (zero-padded to GTIN-13) starts with the scope
    value.
- `action=exclude` → drop the barcode. `action=reattribute` → emit it with
  override columns (below).
- Ship the rules themselves in the SQLite (`exceptions` table, same columns)
  so the **app can apply the same logic to online lookups** — today
  `matchTargetBrand(slugs:)` would happily call a US KitKat (online hit with
  `[kitkat, hershey-s]`) a match; `AppModel.applyOnline` must consult
  `exceptions` for co-brand rules before upgrading to `.match`.

### Schema (additive only)

- `barcodes` gains nullable `maker_override TEXT` and `override_note TEXT`
  (old apps' `SELECT`s ignore them).
- New `exceptions` table as above.
- Optional `schema_version` field in the manifest (old apps ignore unknown
  JSON keys; new apps can gate features on it).

### App design

- `BarcodeDatabase.lookup` reads the override columns; when present the
  verdict is **`.notTarget`** with `manufacturer = actual_maker` and the note
  surfaced ("Made under license by Hershey in the US"). All four themes
  already render `manufacturer` via `OwnershipResult.fields`; add the note
  line.
- Online path: after `matchTargetBrand` hits, check co-brand exceptions
  against the full `hit.brandSlugs`; on a `reattribute` match, emit the same
  `.notTarget` + maker result; on `exclude`, stay `.unknown`.

### Guardrails & tests

- `test_spike.py`: add a **US KitKat anchor** (pick a real barcode with
  `hershey-s` co-brand at implementation time) asserting it is *not* a clean
  match; keep the Coca-Cola negative anchor.
- `test_parsing.py`: rule-application unit tests (each scope type, exclude vs
  reattribute, multi-country ambiguity does not trigger).
- Swift: lookup returns `.notTarget` + maker for an override row (extend the
  SQLite fixture); `applyOnline` demotes a co-branded online hit; stale-guard
  behavior unchanged.
- Pipeline fails if `exceptions.csv` references a `brand_slug` that doesn't
  exist (catches typos) or is missing a citation.

### Risks

- Over-broad country rules could exclude legitimate products → prefer
  `co_brand`/`prefix` scopes when available, and require unambiguous country
  evidence for `country` scopes.
- Curation is judgment work — keep the file small, cited, and reviewed.

**Effort:** 2–3 days including app UI copy. **Dependencies:** co-brand rules
work today; country/owner evidence needs W2.

---

## W4 — GS1 company-prefix inference (hedged coverage multiplier)

**Goal:** classify barcodes we've *never seen* by their manufacturer prefix,
derived statistically from our own confirmed data — offline, license-clean,
and clearly labeled as inference.

**Why:** barcodes encode the GS1 company prefix of the brand owner. We hold
~34k confirmed Nestlé barcodes; prefixes densely and exclusively populated by
them (e.g. Nestlé Switzerland's `7613034…` ranges) generalize to products OFF
has never catalogued. This can multiply effective coverage without a single
new data source.

### Design

New pipeline step `build_prefixes.py`, run after barcodes are collected
(**requires W2**, which provides the counter-evidence corpus):

1. Normalize all barcodes to GTIN-13 (zero-pad UPC-A).
2. For candidate prefix lengths **6–10**: for each prefix `P`, count
   `n_target` (confirmed target barcodes under `P`) and `n_other` (dump
   products under `P` whose `brands_tags` contain **no** target slug).
3. Accept `P` iff `n_target ≥ 10` **and** `n_other = 0` (start maximally
   conservative; loosen to a ratio only with evidence). Emit the **longest**
   accepted form of overlapping prefixes; lookup uses longest-prefix-wins.
4. **Hard exclusions:** restricted-circulation and internal-use ranges
   (GTIN-13 leading `02…`, `04…`, `2…` variable-weight), ISBN (`978`/`979`),
   coupons, and anything shorter than 6 digits.
5. Ship as a new `prefixes` table:
   `prefix TEXT PRIMARY KEY, parent TEXT, is_target INTEGER, evidence_count
   INTEGER, source TEXT` (small — expect tens to low hundreds of rows).
6. W3's `prefix`-scoped exceptions are applied here too (a Hershey prefix can
   never be accepted).

### App design

- Lookup order: exact barcode match → prefix longest-match → unknown.
- A prefix hit is a **hedged** result: `OwnershipResult` gains a
  `matchBasis` (`exact` / `inferredFromPrefix`); verdict stays `.match` but
  every theme renders the hedge ("Likely Nestlé — this barcode's manufacturer
  code belongs to Nestlé; N known products").
- **One-way rule:** prefix inference may only *add* hedged positives. It never
  produces `.notTarget`, never overrides an exact match, never suppresses an
  exception.

### Guardrails & tests

- Pipeline unit tests with synthetic corpora: dense-and-exclusive prefix
  accepted; mixed prefix rejected; excluded ranges rejected; longest-prefix
  emission.
- Workflow summary reports accepted-prefix count and total `evidence_count` —
  a sudden swing is a red flag (extend `check_counts.py` to guard the prefix
  count once stable).
- Swift: hedged verdict rendering; longest-prefix-wins; a Coca-Cola barcode
  matches no prefix (negative anchor); exact match beats prefix match.
- `test_spike.py`: at least one real Nestlé barcode absent from `barcodes` but
  under an accepted prefix resolves as a hedged match (select at
  implementation time).

### Risks

- Prefix boundaries are inferred, not licensed from GS1 — wrong splits create
  false positives. Containment: conservative thresholds, `n_other = 0`,
  exclusion ranges, hedged copy, and the exceptions table.
- Private-label goods manufactured by Nestlé for retailers carry the
  retailer's prefix (missed — acceptable) and vice versa (blocked by
  `n_other = 0`).

**Effort:** 2–3 days. **Dependencies:** W2 (counter-evidence), W3 (prefix
exceptions).

---

## W5 — Close the loop: contribute misses back to Open Food Facts

**Goal:** turn every "No match" into a chance to improve the next daily build
— using OFF as the crowdsourcing backend so we keep zero servers, zero
accounts, zero new privacy surface.

### Design

- On an unknown verdict (and in `ManualSearchView` empty results), show a
  low-key action: **"Not found? Add it to Open Food Facts"** linking to
  `https://world.openfoodfacts.org/cgi/product.pl?type=add&code=<barcode>`
  (verify the exact add-product URL at implementation time), opened in the
  external browser / `SFSafariViewController`.
- Copy notes the flow: contributions land in OFF and reach isNestle after the
  next daily dataset build (~24–48 h).
- Privacy: the barcode leaves the device **only on explicit tap**, to OFF —
  the same party as the existing opt-in lookup. Add one line to
  `docs/privacy.html` and the in-app disclosure; the default posture is
  unchanged.
- Settings/About: extend the existing ODbL attribution with a short
  "contribute" blurb — supporting the commons the app depends on.

### Guardrails & tests

- Unit test: the contribution URL is built correctly (barcode percent-encoded)
  and the affordance appears only for `.unknown` results.
- No analytics on tap-through (consistent with the no-telemetry stance).

**Effort:** ~half a day. **Dependencies:** none.

---

## Sequencing, metrics, and definition of done

| Order | Workstream | Attacks | Effort | Needs |
|---|---|---|---|---|
| 1 | W1 reconciliation | A | ~1 day | — |
| 2 | W2 bulk dump | A (+ enables B) | 1–2 days | — |
| 3 | W3 exceptions | **B** | 2–3 days | W2 for region/owner evidence |
| 4 | W4 prefix inference | A | 2–3 days | W2, W3 |
| 5 | W5 OFF loop | A (long-term) | ~0.5 day | — |

**Metrics to publish in each workflow summary:** brand-slug match rate,
brands/barcodes counts (existing), exception rule count, accepted prefix
count. The match rate is the headline number for Problem A; the US-KitKat
anchor staying green is the headline for Problem B.

**Definition of done for the whole effort:**

- Match rate materially above the 53% baseline with the growth explained by
  provenance (not collisions).
- A US KitKat scan yields "Made under license by Hershey in the US" — not
  "Nestlé — avoid" and not a silent miss.
- All negative controls green; shrink guard extended to the new tables; every
  new row traceable to an ODbL/CC0 source or a cited curated rule.
- Old app binaries still consume new datasets (additive-only schema verified
  by keeping a pre-change binary's queries in a compatibility test).

**Spec bookkeeping:** when implementation starts, fold the durable decisions
into the spec elements via `/update-spec` (FEATURES.md: hedged/licensed
verdict semantics; STACK.md: bulk-dump source; CONTEXT.md: curation workflow)
and update `FINDINGS.md` with the new match-rate measurements.
