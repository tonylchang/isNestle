#!/usr/bin/env python3
"""build_db.py — assemble out/isnestle.sqlite from the two CSVs (isNestle M0, Agent B).

Loads ``out/brands.csv`` (Agent A) and ``out/barcodes.csv`` (Agent B) into the
schema defined by ``schema.sql``. Idempotent: tables are dropped and rebuilt on
every run, and rows are inserted with INSERT OR REPLACE.

Stdlib only (csv/sqlite3). Run:
    python3 build_db.py [--brands out/seed_brands.csv]
"""
from __future__ import annotations

import argparse
import csv
import sqlite3
import sys

import common


def read_rows(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build the isNestle SQLite dataset.")
    parser.add_argument("--brands", default=str(common.BRANDS_CSV),
                        help="path to brands CSV to load (default: out/brands.csv)")
    args = parser.parse_args(argv)

    common.ensure_out()

    try:
        brand_rows = read_rows(args.brands)
    except FileNotFoundError:
        print(f"ERROR: brands file not found: {args.brands}\n"
              f"       Pass --brands out/seed_brands.csv during development.",
              file=sys.stderr)
        return 2
    try:
        barcode_rows = read_rows(common.BARCODES_CSV)
    except FileNotFoundError:
        print(f"ERROR: {common.BARCODES_CSV} not found — run build_barcodes.py first.",
              file=sys.stderr)
        return 2

    schema_sql = common.SCHEMA_SQL.read_text(encoding="utf-8")

    conn = sqlite3.connect(common.SQLITE_DB)
    try:
        cur = conn.cursor()
        # Idempotent clean rebuild.
        cur.executescript("DROP TABLE IF EXISTS barcodes; DROP TABLE IF EXISTS brands;")
        cur.executescript(schema_sql)

        cur.executemany(
            "INSERT OR REPLACE INTO brands (brand_slug, brand_name, parent, is_target) "
            "VALUES (?, ?, ?, ?)",
            [
                (
                    (r.get("brand_slug") or "").strip(),
                    (r.get("brand_name") or "").strip(),
                    (r.get("parent") or common.PARENT_DEFAULT).strip(),
                    int(str(r.get("is_target") or "1").strip() or "1"),
                )
                for r in brand_rows
                if (r.get("brand_slug") or "").strip()
            ],
        )

        known_slugs = {row[0] for row in cur.execute("SELECT brand_slug FROM brands")}
        loaded_barcodes = 0
        orphans = 0
        bc_values = []
        for r in barcode_rows:
            bc = (r.get("barcode") or "").strip()
            slug = (r.get("brand_slug") or "").strip()
            if not bc or not slug:
                continue
            if slug not in known_slugs:
                orphans += 1  # references a slug absent from this brands file
            bc_values.append((bc, slug, (r.get("source") or "").strip() or None))
            loaded_barcodes += 1
        cur.executemany(
            "INSERT OR REPLACE INTO barcodes (barcode, brand_slug, source) VALUES (?, ?, ?)",
            bc_values,
        )
        conn.commit()

        n_brands = cur.execute("SELECT COUNT(*) FROM brands").fetchone()[0]
        n_barcodes = cur.execute("SELECT COUNT(*) FROM barcodes").fetchone()[0]
    finally:
        conn.close()

    print(f"Built {common.SQLITE_DB}")
    print(f"  brands:   {n_brands} (from {args.brands})")
    print(f"  barcodes: {n_barcodes} (from {common.BARCODES_CSV})")
    if orphans:
        print(f"  note: {orphans} barcode rows reference a slug not in this brands file")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
