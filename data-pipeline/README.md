# data-pipeline — Milestone 0 (Data Spike)

Goal of this milestone (see `/spec/elements/PROJECT.md`): **prove** that we can
go from a scanned barcode to a correct "made by Nestlé?" verdict by combining two
open data sources, and surface the known-hard part (brand-name normalization)
before any app code is written.

**Done when:** looking up a real Nestlé product barcode (e.g., a KitKat or Nescafé)
in the assembled SQLite resolves to `parent = Nestlé`, and a non-Nestlé barcode does not.

## Data sources (verified reachable during setup)

| Layer | Source | Access method | License |
|-------|--------|---------------|---------|
| brand → parent | Wikidata (`Q160746`) + Wikipedia "List of Nestlé brands" | SPARQL `query.wikidata.org/sparql` (HTTP 200 OK) | CC0 |
| barcode → brand | **OFF family** — Open Food Facts + Open Pet Food / Beauty / Products Facts | TSV dumps from `static.open*facts.org`; API search remains the per-dataset fallback | ODbL |

The barcode side streams the whole **OFF family** (`build_barcodes.py`), not just
OFF, so non-food gaps close — **Open Pet Food Facts** in particular covers the
Purina / pet-care products OFF lacks. All four DBs are ODbL, so every barcode is
bundle-able; barcodes are de-duplicated across them (OFF wins ties). Limit the
fan-out with `--datasets off,opff` (ids: `off`, `opff`, `obf`, `opf`).

Dump mode is the production path because it avoids search-window caps and gives
the exception/prefix steps country and co-brand evidence. If a dataset dump is
temporarily unavailable, that dataset falls back to API search while successful
dump datasets are kept.

## The contract (`common.py` + `schema.sql`)

Both halves of the pipeline import `common.py` so they cannot drift:
- `off_slug(name)` — the single brand-slug normalizer.
- `http_get_json(...)` — resilient GET (User-Agent, retries, backoff).
- shared paths/constants; `schema.sql` is the SQLite DDL.

## Pieces

| Script | Owner | Produces |
|--------|-------|----------|
| `build_brands.py` | brand table | `out/brands.csv` (brand_slug, brand_name, parent, is_target) |
| `reconcile_brands.py` | brand-tag reconciliation | updates `out/brands.csv`; writes `out/alias_review.txt` |
| `build_barcodes.py` | barcode pipeline | `out/barcodes.csv` (old columns plus nullable override metadata) |
| `build_prefixes.py` | prefix inference | `out/prefixes.csv` |
| `build_db.py` | assembly | `out/isnestle.sqlite` (both tables) |
| `test_spike.py` | validation | PASS/FAIL + normalization match-rate report |
| `test_parsing.py` | unit tests | offline tests for the parsing/normalization functions |
| `check_counts.py` | publish guard | fails CI if counts shrank >10% vs the last release |

## Run

```bash
python3 build_brands.py      # -> out/brands.csv
python3 reconcile_brands.py  # merges aliases.csv; writes out/alias_review.txt
python3 build_barcodes.py    # dump mode by default; API fallback; -> out/barcodes.csv
python3 build_prefixes.py    # reads out/barcodes.csv + out/prefix_corpus.csv
python3 build_db.py          # -> out/isnestle.sqlite
python3 build_manifest.py    # -> out/manifest.json (version, sha256, counts)
python3 test_spike.py        # asserts the spike's done-criterion
```

Stdlib only (Python 3.12+ in CI): `urllib`, `json`, `csv`, `sqlite3`, `hashlib`.
No pip installs. `out/` is gitignored (regenerate by re-running).

Reviewed data files:

- `aliases.csv` — accepted brand-tag aliases. Fuzzy matches from
  `out/alias_review.txt` do not affect the dataset until committed here.
- `exceptions.csv` — cited false-positive rules. Keep this file small and
  conservative; every row must carry a public `source_url`.

Barcode collection defaults to OFF-family dump streaming (`--mode dump`) and
falls back to API mode if a dump fetch/parse fails. Use `--mode api` for a
lighter local run. Prefix inference requires the dump-mode counter-evidence
corpus; API-mode builds write zero prefixes by design.

## Daily publication

`.github/workflows/dataset.yml` runs this pipeline daily on GitHub Actions and
publishes `isnestle.sqlite` + `manifest.json` to the rolling **`dataset-latest`**
GitHub Release. The app checks `manifest.json` and self-updates (see
`app/isNestle/Data/DatasetUpdater.swift`). The app also bundles a baseline
`dataset_manifest.json` (copy of a `manifest.json`) as its install-time version.

Before publishing, the workflow runs `check_counts.py` against the previously
published manifest and **fails if brands or barcodes shrank more than 10%** —
a degraded source (OFF search flake, Wikipedia format drift) shrinks the output
rather than erroring, and this guard keeps such a build from shipping to users.

The workflow also **signs `manifest.json`** (Ed25519, key in the
`dataset-publish` environment secret) and publishes the detached
`manifest.json.sig`; the app refuses to install a dataset whose manifest isn't
signed by a baked-in trusted key. See `RELEASE.md` for key management.
