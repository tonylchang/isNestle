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
| barcode → brand | **OFF family** — Open Food Facts + Open Pet Food / Beauty / Products Facts | OFF via **Search-a-licious** `search.openfoodfacts.org`; siblings via classic `world.open{pet,beauty,products}facts.org/api/v2/search?brands_tags=<slug>` | ODbL |

The barcode side queries the whole **OFF family** (`build_barcodes.py`), not just
OFF, so non-food gaps close — **Open Pet Food Facts** in particular covers the
Purina / pet-care products OFF lacks. All four DBs are ODbL, so every barcode is
bundle-able; barcodes are de-duplicated across them (OFF wins ties). Limit the
fan-out with `--datasets off,opff` (ids: `off`, `opff`, `obf`, `opf`).

> Only OFF runs Search-a-licious; the siblings redirect, so they use the classic
> `/api/v2/search` (fine — those DBs are small). Guessing individual barcodes
> proved unreliable. The full 9 GB OFF bulk dump is **out of scope for the spike**;
> it belongs to the production daily pipeline (`INFRA.md`).

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

Stdlib only (Python 3.12+ in CI): `urllib`, `json`, `csv`, `sqlite3`, `hashlib`.
No pip installs. `out/` is gitignored (regenerate by re-running).

## Daily publication

`.github/workflows/dataset.yml` runs this pipeline daily on GitHub Actions and
publishes `isnestle.sqlite` + `manifest.json` to the rolling **`dataset-latest`**
GitHub Release. The app checks `manifest.json` and self-updates (see
`app/isNestle/Data/DatasetUpdater.swift`). The app also bundles a baseline
`dataset_manifest.json` (copy of a `manifest.json`) as its install-time version.
