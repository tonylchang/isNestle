# Milestone 0 — Data Spike Findings

**Result: PASS.** A scanned barcode can be resolved to a correct "made by Nestlé?"
verdict by combining two open data sources, fully offline, in a small SQLite file.

> Updated after the full refresh: Wikidata's portfolio is now merged in (the
> initial spike ran Wikipedia + curated only, during a WDQS outage).

## What was proven

- **Done-criterion met:** real Nestlé barcodes (Aero, Milkybar, …) resolve to
  `parent = Nestlé, is_target = 1`; a non-Nestlé barcode (Coca-Cola Fuze Tea)
  returns no match → "Unknown". Verified by `test_spike.py` (6/6) and raw SQL.
- **Pipeline shape works:** Wikidata + Wikipedia + curated → `brands` table;
  Open Food Facts (Search-a-licious) → `barcodes` table; assembled into
  `isnestle.sqlite`.

## The dataset produced

| Metric | Value |
|--------|-------|
| Brands (brand → Nestlé) | 601 |
| Real barcodes (from OFF family) | 33,424 |
| SQLite size | ~2.9 MB |
| Network at scan time | none (fully offline) |

Tiny and offline — exactly the on-device shape `STACK.md` envisions.

## Key findings (the real value of the spike)

### 1. Brand-name normalization is the central problem — quantified
Only **319 / 601 (53%)** of brand slugs matched an OFF-family `brands_tags` value. The
misses are dominated by **legitimate but obscure regional brands** absent from
the public product datasets (Abuelita, Ricoffy, Golden Morn…) plus categories
where coverage is still thin.

OFF's tagger is also inconsistent about hyphenation: **`kitkat` and `kit-kat`
are both real, separately-populated tags** (487 vs 253 products). The brand list
must carry slug variants and/or fuzzy-reconcile against actual tags.

### 2. Wikidata's ownership graph needs cleaning at two layers
- **Over-inclusion via minority stakes:** the transitive ownership closure pulls
  in entire unrelated empires (L'Oréal, Galderma, Alcon, Sanofi/Novartis). Pruned
  by excluding those QID subtrees in the SPARQL + a slug denylist.
- **Patents-as-brands:** the `P176` ("manufacturer") edge drags in Nestlé's
  **patent portfolio** as fake brands — `method-for-cooking-food-…`,
  `compositions-comprising-human-milk-oligosaccharides-…` (147 such rows). Removed
  by a high-precision non-brand filter (`is_non_brand_noise`): drops ≥6-word
  patent-style phrases and telltale tokens (composition/method/apparatus/…) while
  sparing real multi-word lines like `purina-pro-plan-veterinary-diets`.

### 3. Parent attribution can be genuinely ambiguous
US KitKats carry `hershey-s` in `brands_tags` — Hershey manufactures KitKat under
license in the US. So a single barcode can map to different parents by region.
The eventual data model may need to represent "made by X, in region Y."

## Caveats

- **Wikidata Query Service is rate-limited during its active outage** (~1 req/min).
  `build_brands.py` waits out the window (~65 s) between attempts; a healthy WDQS
  will be much faster.
- **Barcode coverage expanded post-spike.** The 25/brand spike cap was removed in
  favor of full pagination (250/page, up to OFF's 10k result window) — the dataset
  is now **33,424 barcodes** (~2.9 MB SQLite), with **no brand exceeding the
  window**. The full OFF bulk dump remains the eventual production source (see
  `INFRA.md`) for products beyond what Search-a-licious returns (e.g. pet care).

## Incident 2026-07-02 — WDQS outage → L'Oréal contamination (fixed)

A dispatched build exposed a real defect. WDQS rate-limited the **rich
(subtree-excluding) SPARQL query** (HTTP 429, "active wdqs outage"), and the
pipeline fell back to the **plain transitive query**, which applies **no**
minority-stake/divested exclusion. That imported the entire L'Oréal / Sanofi /
Alcon ownership closure as `is_target=1` "Nestlé" brands. The per-slug denylist
only caught a hardcoded handful, so `l-oreal-paris` (184 barcodes), `biotherm`
(20), `l-oreal-professionnel` (14), `cadum`, `aesop`, … shipped in release
`2026.07.02.0217` — a false-positive/defamation problem, since L'Oréal is a
Nestlé **minority stake**, not a subsidiary.

Fixes:
- **`fetch_wikidata` now uses ONLY the exclusion query** — no unpruned plain
  fallback. If WDQS is unavailable, Wikidata is dropped for the run (degrade to
  Wikipedia + curated, the known-clean baseline). A smaller clean list beats a
  larger contaminated one; `check_counts.py` + the anchors below catch a shrink.
- **L'Oréal negative anchors in `test_spike.py`** — known L'Oréal barcodes must
  never resolve as a target match, so a contaminated brand list can't publish.
- Broadened `DENY_SLUGS` (belt-and-suspenders only).

Separately, **dump mode under-collected** (8,425 OFF barcodes vs ~25k via the
API; missed the Aero/Milkybar anchors), so the spike correctly blocked it. The
daily workflow reverted to `--mode api` until the bulk-dump parser is fixed
(likely a `brands_tags` column-format mismatch in the CSV export — to diagnose).

## Implications for the build

- Treat the brand list as **brands, not products/patents**, with explicit
  slug-variant / alias handling and the non-brand filter — promote these from
  footnotes to real pipeline steps.
- Plan a **secondary source for pet care** (Purina) and other OFF-thin categories.
- Keep the `parent` attribution model flexible enough for licensing/region
  ambiguity before it bites at scale.
