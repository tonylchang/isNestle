#!/usr/bin/env python3
"""build_barcodes.py — OFF-family barcode pipeline (isNestle, Agent B).

For every ``brand_slug`` in the brands CSV, query each OFF-family database for
real product barcodes whose ``brands_tags`` contain that exact slug, and emit
``out/barcodes.csv`` (header: ``barcode,brand_slug,source``).

The OFF *family* is queried, not just OFF, so non-food gaps are covered:
  - Open Food Facts      (food)               — Search-a-licious (fast)
  - Open Pet Food Facts  (pet care / Purina)  — classic /api/v2/search
  - Open Beauty Facts    (cosmetics)          — classic /api/v2/search
  - Open Products Facts  (household)          — classic /api/v2/search
All four are ODbL, so every barcode here is bundle-able. The siblings don't run
Search-a-licious, so they use the classic Product Opener REST API.

A barcode "matches" only when one of its ``brands_tags`` is *exactly equal* to a
known brand_slug (no fuzzy matching) — this is what lets us reconcile our
normalized slugs against each DB's own tagger and measure the normalization gap.
Barcodes are globally de-duplicated across datasets; the first dataset to claim a
barcode (OFF first) wins its provenance.

Stdlib only (urllib/json/csv via common). Run:
    python3 build_barcodes.py [--brands out/seed_brands.csv] [--datasets off,opff]
"""
from __future__ import annotations

import argparse
import csv
import sys
import time

import common

RESULT_WINDOW = 10000     # OFF/Elasticsearch max_result_window (hard upper bound)
SLEEP_SECONDS = 0.4       # short pause between requests (be polite to the APIs)

# OFF-family datasets (all ODbL). Each turns brand slugs into real barcodes.
#   kind="salicious": Search-a-licious (OFF only; fast, page_size up to 250,
#                     results under "hits").
#   kind="v2":        classic Product Opener REST API (siblings; page_size up to
#                     100, results under "products").
DATASETS = [
    {"id": "off",  "name": "Open Food Facts",     "kind": "salicious", "url": common.OFF_SEARCH_URL},
    {"id": "opff", "name": "Open Pet Food Facts", "kind": "v2",        "url": common.OPFF_SEARCH_URL},
    {"id": "obf",  "name": "Open Beauty Facts",   "kind": "v2",        "url": common.OBF_SEARCH_URL},
    {"id": "opf",  "name": "Open Products Facts", "kind": "v2",        "url": common.OPF_SEARCH_URL},
]
DATASETS_BY_ID = {d["id"]: d for d in DATASETS}
PAGE_SIZE_BY_KIND = {"salicious": 250, "v2": 100}


def read_brand_slugs(path: str) -> list[str]:
    """Read brand_slug values (in file order, de-duplicated) from a brands CSV."""
    slugs: list[str] = []
    seen: set[str] = set()
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            slug = (row.get("brand_slug") or "").strip()
            if slug and slug not in seen:
                seen.add(slug)
                slugs.append(slug)
    return slugs


def fetch_for_slug(slug: str, dataset: dict) -> tuple[list[str], int]:
    """Return (barcodes matching this slug exactly, total count) for one dataset.

    Paginates the full result set (up to the result window) so we get complete
    coverage rather than a sample. Handles both API shapes: Search-a-licious
    returns hits under ``hits``; the classic v2 API returns them under
    ``products`` and takes ``brands_tags`` as a plain filter param.
    """
    kind = dataset["kind"]
    url = dataset["url"]
    page_size = PAGE_SIZE_BY_KIND[kind]
    results_key = "hits" if kind == "salicious" else "products"

    codes: list[str] = []
    total = 0
    page = 1
    while True:
        if kind == "salicious":
            params = {"q": f"brands_tags:{slug}", "fields": "code,brands_tags",
                      "page_size": page_size, "page": page}
        else:  # classic v2 search
            params = {"brands_tags": slug, "fields": "code,brands_tags",
                      "page_size": page_size, "page": page}
        data = common.http_get_json(url, params)
        if page == 1:
            total = int(data.get("count") or 0)
        hits = data.get(results_key) or []
        if not hits:
            break
        for hit in hits:
            code = (hit.get("code") or "").strip()
            tags = hit.get("brands_tags") or []
            # Exact-match reconciliation against the DB's own tags.
            if code and slug in tags:
                codes.append(code)
        fetched = page * page_size
        if fetched >= total or fetched >= RESULT_WINDOW:
            break
        page += 1
        time.sleep(SLEEP_SECONDS)
    return codes, total


def run_dataset(dataset: dict, slugs: list[str],
                collected: dict[str, tuple[str, str]]) -> dict:
    """Query one dataset for every slug, adding new barcodes to ``collected``.

    ``collected`` maps barcode -> (brand_slug, source_id); the first dataset to
    claim a barcode keeps it (datasets run in priority order, OFF first). Returns
    a per-dataset stats dict.
    """
    src = dataset["id"]
    print(f"\n[{src}] {dataset['name']} ({dataset['kind']})")
    kept_total = 0
    new_total = 0
    slugs_with_hits = 0
    zero_hits: list[str] = []

    for slug in slugs:
        try:
            codes, total = fetch_for_slug(slug, dataset)
        except Exception as exc:  # network/JSON already retried inside http_get_json
            print(f"  {slug:24} ERROR {exc!r}")
            zero_hits.append(slug)
            time.sleep(SLEEP_SECONDS)
            continue

        new = 0
        for code in codes:
            if code not in collected:
                collected[code] = (slug, src)
                new += 1
        kept_total += len(codes)
        new_total += new
        if codes:
            slugs_with_hits += 1
            capped = " (window-capped)" if total > RESULT_WINDOW else ""
            print(f"  {slug:24} total={total:>6}  kept={len(codes):>4}  new={new:>4}{capped}")
        else:
            zero_hits.append(slug)
        time.sleep(SLEEP_SECONDS)

    print(f"  -> {new_total} new barcodes from {slugs_with_hits}/{len(slugs)} slugs")
    return {"id": src, "kept": kept_total, "new": new_total,
            "slugs_with_hits": slugs_with_hits, "zero_hits": zero_hits}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect OFF-family barcodes for known brand slugs.")
    parser.add_argument("--brands", default=str(common.BRANDS_CSV),
                        help="path to brands CSV (default: out/brands.csv)")
    parser.add_argument("--datasets", default=",".join(d["id"] for d in DATASETS),
                        help="comma-separated dataset ids to query "
                             f"(default: all — {', '.join(DATASETS_BY_ID)})")
    args = parser.parse_args(argv)

    ids = [s.strip() for s in args.datasets.split(",") if s.strip()]
    unknown = [i for i in ids if i not in DATASETS_BY_ID]
    if unknown:
        print(f"ERROR: unknown dataset id(s): {', '.join(unknown)}\n"
              f"       known ids: {', '.join(DATASETS_BY_ID)}", file=sys.stderr)
        return 2
    selected = [DATASETS_BY_ID[i] for i in ids]

    try:
        slugs = read_brand_slugs(args.brands)
    except FileNotFoundError:
        print(f"ERROR: brands file not found: {args.brands}\n"
              f"       Run build_brands.py, or pass --brands out/seed_brands.csv",
              file=sys.stderr)
        return 2

    if not slugs:
        print(f"ERROR: no brand_slug values in {args.brands}", file=sys.stderr)
        return 2

    common.ensure_out()
    print(f"OFF-family barcode pipeline: {len(slugs)} brand slugs from {args.brands}")
    print(f"datasets: {', '.join(d['id'] for d in selected)}")

    # barcode -> (brand_slug, source_id); first dataset/slug to claim a barcode wins.
    collected: dict[str, tuple[str, str]] = {}
    stats = [run_dataset(d, slugs, collected) for d in selected]

    # Write barcodes.csv, sorted by barcode for deterministic output.
    rows = sorted(((bc, s, src) for bc, (s, src) in collected.items()))
    with open(common.BARCODES_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["barcode", "brand_slug", "source"])
        w.writerows(rows)

    # ---- Summary -------------------------------------------------------------
    print(f"\n{'=' * 60}")
    print(f"Wrote {len(rows)} unique barcodes -> {common.BARCODES_CSV}")
    for st in stats:
        print(f"  {st['id']:5} contributed {st['new']:>6} barcodes "
              f"({st['slugs_with_hits']} slugs hit)")

    # A zero-OFF-hit slug is a *normalization* miss (the brand exists but our slug
    # didn't match OFF's tag); a zero-hit in a sibling just means the brand isn't
    # in that category — only worth flagging for OFF.
    off_stat = next((s for s in stats if s["id"] == "off"), None)
    if off_stat and off_stat["zero_hits"]:
        misses = off_stat["zero_hits"]
        shown = ", ".join(misses[:30]) + (" …" if len(misses) > 30 else "")
        print(f"\nOFF normalization misses ({len(misses)} slugs with zero OFF hits): {shown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
