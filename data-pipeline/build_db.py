#!/usr/bin/env python3
"""build_db.py — assemble out/isnestle.sqlite from pipeline CSVs.

Loads ``out/brands.csv``, ``out/barcodes.csv``, reviewed ``exceptions.csv``, and
``out/prefixes.csv`` into the additive schema defined by ``schema.sql``.
Idempotent: tables are dropped and rebuilt on every run, and rows are inserted
with INSERT OR REPLACE.

Stdlib only (csv/sqlite3). Run:
    python3 build_db.py [--brands out/seed_brands.csv]
"""
from __future__ import annotations

import argparse
import csv
import sqlite3
import sys

import common
import rules


def read_rows(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def read_optional_rows(path) -> list[dict]:
    if not path.exists():
        return []
    return read_rows(str(path))


def nullable_int(value):
    s = str(value or "").strip()
    return int(s) if s else None


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
        cur.execute("PRAGMA foreign_keys = ON")
        # Idempotent clean rebuild.
        cur.executescript(
            "DROP TABLE IF EXISTS prefixes; "
            "DROP TABLE IF EXISTS exceptions; "
            "DROP TABLE IF EXISTS barcodes; "
            "DROP TABLE IF EXISTS brands;"
        )
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
        try:
            exception_rules = rules.read_exception_rules(common.EXCEPTIONS_CSV, known_slugs)
        except rules.RuleError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 2

        cur.executemany(
            "INSERT INTO exceptions "
            "(brand_slug, scope_type, scope_value, actual_maker, action, note, source_url) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    r.brand_slug,
                    r.scope_type,
                    r.scope_value,
                    r.actual_maker or None,
                    r.action,
                    r.note,
                    r.source_url,
                )
                for r in exception_rules
            ],
        )

        loaded_barcodes = 0
        orphans = 0
        missing_barcode_sources = 0
        bc_values = []
        for r in barcode_rows:
            bc = (r.get("barcode") or "").strip()
            slug = (r.get("brand_slug") or "").strip()
            if not bc or not slug:
                continue
            if slug not in known_slugs:
                orphans += 1  # references a slug absent from this brands file
                continue
            source = (r.get("source") or "").strip()
            if not source:
                missing_barcode_sources += 1
                continue
            bc_values.append(
                (
                    bc,
                    slug,
                    source,
                    (r.get("maker_override") or "").strip() or None,
                    (r.get("override_note") or "").strip() or None,
                    (r.get("match_basis") or "").strip() or None,
                    nullable_int(r.get("evidence_count")),
                )
            )
            loaded_barcodes += 1
        if orphans:
            print(f"ERROR: {orphans} barcode rows reference a slug not in this brands file", file=sys.stderr)
            return 1
        if missing_barcode_sources:
            print(f"ERROR: {missing_barcode_sources} barcode rows are missing source provenance", file=sys.stderr)
            return 1
        cur.executemany(
            "INSERT OR REPLACE INTO barcodes "
            "(barcode, brand_slug, source, maker_override, override_note, match_basis, evidence_count) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            bc_values,
        )

        prefix_rows = read_optional_rows(common.PREFIXES_CSV)
        cur.executemany(
            "INSERT OR REPLACE INTO prefixes (prefix, parent, is_target, evidence_count, source) "
            "VALUES (?, ?, ?, ?, ?)",
            [
                (
                    (r.get("prefix") or "").strip(),
                    (r.get("parent") or common.PARENT_DEFAULT).strip(),
                    int(str(r.get("is_target") or "1").strip() or "1"),
                    int(str(r.get("evidence_count") or "0").strip() or "0"),
                    (r.get("source") or "").strip() or "prefix-inference",
                )
                for r in prefix_rows
                if (r.get("prefix") or "").strip()
            ],
        )
        conn.commit()

        n_brands = cur.execute("SELECT COUNT(*) FROM brands").fetchone()[0]
        n_barcodes = cur.execute("SELECT COUNT(*) FROM barcodes").fetchone()[0]
        n_exceptions = cur.execute("SELECT COUNT(*) FROM exceptions").fetchone()[0]
        n_prefixes = cur.execute("SELECT COUNT(*) FROM prefixes").fetchone()[0]
    finally:
        conn.close()

    print(f"Built {common.SQLITE_DB}")
    print(f"  brands:     {n_brands} (from {args.brands})")
    print(f"  barcodes:   {n_barcodes} (from {common.BARCODES_CSV})")
    print(f"  exceptions: {n_exceptions} (from {common.EXCEPTIONS_CSV})")
    print(f"  prefixes:   {n_prefixes} (from {common.PREFIXES_CSV})")
    if orphans:
        print(f"  note: {orphans} barcode rows reference a slug not in this brands file")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
