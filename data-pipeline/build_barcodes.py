#!/usr/bin/env python3
"""build_barcodes.py — Open Food Facts barcode pipeline (isNestle M0 spike, Agent B).

For every ``brand_slug`` in the brands CSV, query OFF Search-a-licious for real
product barcodes whose ``brands_tags`` contain that exact slug, and emit
``out/barcodes.csv`` (header: ``barcode,brand_slug,source``).

A barcode "matches" only when one of its OFF ``brands_tags`` is *exactly equal* to
a known brand_slug (no fuzzy matching) — this is what lets us reconcile our
normalized slugs against OFF's own tagger and measure the normalization gap.

Stdlib only (urllib/json/csv via common). Run:
    python3 build_barcodes.py [--brands out/seed_brands.csv]
"""
from __future__ import annotations

import argparse
import csv
import sys
import time

import common

PAGE_SIZE = 25            # modest page size — be polite to OFF
CAP_PER_BRAND = 25        # SPIKE CAP: at most this many barcodes per brand
SLEEP_SECONDS = 0.5       # short pause between requests
SOURCE = "off-search-a-licious"


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


def fetch_for_slug(slug: str) -> tuple[list[str], int]:
    """Return (barcodes matching this slug exactly, total OFF count for the slug)."""
    data = common.http_get_json(
        common.OFF_SEARCH_URL,
        {"q": f"brands_tags:{slug}", "fields": "code,brands_tags", "page_size": PAGE_SIZE},
    )
    total = int(data.get("count") or 0)
    codes: list[str] = []
    for hit in data.get("hits", []) or []:
        code = (hit.get("code") or "").strip()
        tags = hit.get("brands_tags") or []
        if not code:
            continue
        # Exact-match reconciliation against OFF's own tags.
        if slug in tags:
            codes.append(code)
        if len(codes) >= CAP_PER_BRAND:
            break
    return codes, total


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect OFF barcodes for known brand slugs.")
    parser.add_argument("--brands", default=str(common.BRANDS_CSV),
                        help="path to brands CSV (default: out/brands.csv)")
    args = parser.parse_args(argv)

    try:
        slugs = read_brand_slugs(args.brands)
    except FileNotFoundError:
        print(f"ERROR: brands file not found: {args.brands}\n"
              f"       Run Agent A's build_brands.py, or pass --brands out/seed_brands.csv",
              file=sys.stderr)
        return 2

    if not slugs:
        print(f"ERROR: no brand_slug values in {args.brands}", file=sys.stderr)
        return 2

    common.ensure_out()
    print(f"OFF barcode pipeline: {len(slugs)} brand slugs from {args.brands}")
    print(f"(spike cap = {CAP_PER_BRAND} barcodes/brand, page_size = {PAGE_SIZE})\n")

    # barcode -> (brand_slug, source); first slug to claim a barcode wins (dedupe).
    collected: dict[str, tuple[str, str]] = {}
    per_slug_kept: dict[str, int] = {}
    per_slug_total: dict[str, int] = {}

    for slug in slugs:
        try:
            codes, total = fetch_for_slug(slug)
        except Exception as exc:  # network/JSON already retried inside http_get_json
            print(f"  {slug:20} ERROR {exc!r}")
            per_slug_kept[slug] = 0
            per_slug_total[slug] = 0
            time.sleep(SLEEP_SECONDS)
            continue

        new = 0
        for code in codes:
            if code not in collected:
                collected[code] = (slug, SOURCE)
                new += 1
        per_slug_kept[slug] = len(codes)
        per_slug_total[slug] = total
        capped = " (capped)" if total > CAP_PER_BRAND else ""
        print(f"  {slug:20} off_total={total:>6}  kept={len(codes):>3}  new={new:>3}{capped}")
        time.sleep(SLEEP_SECONDS)

    # Write barcodes.csv, sorted by barcode for deterministic output.
    rows = sorted(((bc, s, src) for bc, (s, src) in collected.items()))
    with open(common.BARCODES_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["barcode", "brand_slug", "source"])
        w.writerows(rows)

    zero_hits = [s for s in slugs if per_slug_kept.get(s, 0) == 0]
    print(f"\nWrote {len(rows)} unique barcodes -> {common.BARCODES_CSV}")
    print(f"slugs with >=1 barcode: {len(slugs) - len(zero_hits)}/{len(slugs)}")
    if zero_hits:
        print(f"slugs with ZERO OFF hits (normalization misses): {', '.join(zero_hits)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
