# Milestone 0 — Data Spike Findings

**Result: PASS.** A scanned barcode can be resolved to a correct "made by Nestlé?"
verdict by combining two open data sources, fully offline, in a small SQLite file.

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
| Brands (brand → Nestlé) | 466 |
| Real barcodes (from OFF) | 3,582 |
| SQLite size | ~380 KB |
| Network at scan time | none (fully offline) |

Tiny and offline — exactly the on-device shape `STACK.md` envisions.

## Key findings (the real value of the spike)

### 1. Brand-name normalization is the central problem — now quantified
Only **284 / 466 (61%)** of curated brand slugs matched an OFF `brands_tags`
value. The 182 misses fall into three fixable buckets:

- **Over-specific *product* names that aren't brands** — `nestle-classic`,
  `kit-kat-cereal`, `nesquik-breakfast-cereal`. The list should hold *brands*.
- **Regional / niche brands** absent from OFF (Abuelita, Ricoffy, Golden Morn…).
- **Pet care** — *every* Purina line (`purina-pro-plan`, `purina-cat-chow`, …)
  missed, because OFF is food-focused and barely covers pet products. Purina
  likely needs a non-OFF source.

OFF's tagger is also inconsistent about hyphenation: **`kitkat` and `kit-kat`
are both real, separately-populated tags** (487 vs 253 products). The production
brand list must carry slug variants and/or fuzzy-reconcile against actual tags.

### 2. Parent attribution can be genuinely ambiguous
US KitKats carry `hershey-s` in `brands_tags` — Hershey manufactures KitKat under
license in the US. So a single barcode can map to different parents by region.
The eventual data model may need to represent "made by X, in region Y."

## Caveats

- **Wikidata was mid-outage** (WDQS HTTP 429) during this run, so the brand list
  is currently **Wikipedia + curated only**. Re-running `build_brands.py` once
  WDQS recovers auto-merges ~367 additional brands — no code change needed.
- **Barcodes capped at 25/brand** for the spike (some brands have thousands).
  The production daily pipeline (see `INFRA.md`) should use the full OFF bulk dump
  rather than per-brand API queries.

## Implications for the build

- Treat the brand list as **brands, not products**, with explicit slug-variant /
  alias handling — promote this from a footnote to a real pipeline step.
- Plan a **secondary source for pet care** (Purina) and other OFF-thin categories.
- Keep the `parent` attribution model flexible enough for licensing/region
  ambiguity before it bites at scale.
