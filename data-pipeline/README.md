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
| barcode → brand | Open Food Facts | **Search-a-licious** `search.openfoodfacts.org/search?q=brands_tags:<slug>` (fast & reliable) | ODbL |

> The slow `/api/v2/search` endpoint and guessing individual product barcodes
> proved unreliable — use Search-a-licious. The full 9 GB OFF bulk dump is **out of
> scope for the spike**; it belongs to the production daily pipeline (`INFRA.md`).

## The contract (`common.py` + `schema.sql`)

Both halves of the pipeline import `common.py` so they cannot drift:
- `off_slug(name)` — the single brand-slug normalizer.
- `http_get_json(...)` — resilient GET (User-Agent, retries, backoff).
- shared paths/constants; `schema.sql` is the SQLite DDL.

## Pieces

| Script | Owner | Produces |
|--------|-------|----------|
| `build_brands.py` | brand table | `out/brands.csv` (brand_slug, brand_name, parent, is_target) |
| `build_barcodes.py` | barcode pipeline | `out/barcodes.csv` (barcode, brand_slug, source) |
| `build_db.py` | assembly | `out/isnestle.sqlite` (both tables) |
| `test_spike.py` | validation | PASS/FAIL + normalization match-rate report |

## Run

```bash
python3 build_brands.py      # -> out/brands.csv
python3 build_barcodes.py    # reads out/brands.csv -> out/barcodes.csv
python3 build_db.py          # -> out/isnestle.sqlite
python3 build_manifest.py    # -> out/manifest.json (version, sha256, counts)
python3 test_spike.py        # asserts the spike's done-criterion
```

Stdlib only (Python 3.14): `urllib`, `json`, `csv`, `sqlite3`, `hashlib`. No pip
installs. `out/` is gitignored (regenerate by re-running).

## Daily publication

`.github/workflows/dataset.yml` runs this pipeline daily on GitHub Actions and
publishes `isnestle.sqlite` + `manifest.json` to the rolling **`dataset-latest`**
GitHub Release. The app checks `manifest.json` and self-updates (see
`app/isNestle/Data/DatasetUpdater.swift`). The app also bundles a baseline
`dataset_manifest.json` (copy of a `manifest.json`) as its install-time version.
