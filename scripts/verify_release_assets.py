#!/usr/bin/env python3
"""Verify the bundled release dataset matches its manifest.

Checks are intentionally stdlib-only so the script can run anywhere the repo can
be built: hash, byte size, table counts, version format, SQLite integrity, and
foreign-key integrity.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / "app" / "isNestle" / "Resources" / "isnestle.sqlite"
DEFAULT_MANIFEST = ROOT / "app" / "isNestle" / "Resources" / "dataset_manifest.json"
VERSION_RE = re.compile(r"^\d{4}\.\d{2}\.\d{2}\.\d{4}$")
BASE_REQUIRED_COLUMNS = {
    "brands": {"brand_slug", "brand_name", "parent", "is_target"},
    "barcodes": {"barcode", "brand_slug", "source"},
}
V2_REQUIRED_COLUMNS = {
    "barcodes": {"maker_override", "override_note", "match_basis", "evidence_count"},
    "exceptions": {
        "brand_slug",
        "scope_type",
        "scope_value",
        "actual_maker",
        "action",
        "note",
        "source_url",
    },
    "prefixes": {"prefix", "parent", "is_target", "evidence_count", "source"},
}


def count(con: sqlite3.Connection, table: str) -> int:
    return int(con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


def table_exists(con: sqlite3.Connection, table: str) -> bool:
    return con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?",
        (table,),
    ).fetchone() is not None


def columns(con: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in con.execute(f"PRAGMA table_info({table})")}


def required_columns(table: str, schema_version: int) -> set[str]:
    required = set(BASE_REQUIRED_COLUMNS.get(table, set()))
    if schema_version >= 2:
        required.update(V2_REQUIRED_COLUMNS.get(table, set()))
    return required


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify bundled isNestle release assets.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help=f"SQLite path (default: {DEFAULT_DB})")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST,
                        help=f"manifest path (default: {DEFAULT_MANIFEST})")
    args = parser.parse_args(argv)

    failures: list[str] = []
    if not args.db.exists():
        failures.append(f"missing SQLite: {args.db}")
    if not args.manifest.exists():
        failures.append(f"missing manifest: {args.manifest}")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1

    data = args.db.read_bytes()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))

    expected = {
        "sqlite_bytes": len(data),
        "sqlite_sha256": hashlib.sha256(data).hexdigest(),
    }
    for key, actual in expected.items():
        if manifest.get(key) != actual:
            failures.append(f"{key} mismatch: manifest={manifest.get(key)!r} actual={actual!r}")

    version = manifest.get("version", "")
    if not VERSION_RE.fullmatch(version):
        failures.append(f"version must be YYYY.MM.DD.HHMM, got {version!r}")

    schema_version = int(manifest.get("schema_version") or 1)
    required_manifest_keys = {"brands", "barcodes"}
    if schema_version >= 2:
        required_manifest_keys.update(
            ("exceptions", "prefixes", "matched_brand_slugs", "prefix_evidence_count")
        )

    with sqlite3.connect(args.db) as con:
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            failures.append(f"SQLite integrity_check failed: {integrity}")

        fk_errors = con.execute("PRAGMA foreign_key_check").fetchall()
        if fk_errors:
            failures.append(f"SQLite foreign_key_check found {len(fk_errors)} violation(s)")

        actual_counts = {"brands": count(con, "brands"), "barcodes": count(con, "barcodes")}
        required_tables = {"brands", "barcodes"}
        if schema_version >= 2 or any(key in manifest for key in ("exceptions", "prefixes")):
            required_tables.update(("exceptions", "prefixes"))

        for table in sorted(required_tables):
            if not table_exists(con, table):
                failures.append(f"missing required table: {table}")
                continue
            missing_columns = required_columns(table, schema_version) - columns(con, table)
            if missing_columns:
                failures.append(f"{table} missing column(s): {', '.join(sorted(missing_columns))}")
            actual_counts[table] = count(con, table)

        for table in ("barcodes", "prefixes"):
            if table_exists(con, table) and "source" in columns(con, table):
                missing_source = count(con, table) - int(
                    con.execute(
                        f"SELECT COUNT(*) FROM {table} WHERE source IS NOT NULL AND TRIM(source) <> ''"
                    ).fetchone()[0]
                )
                if missing_source:
                    failures.append(f"{table} has {missing_source} row(s) without source provenance")

        if table_exists(con, "exceptions"):
            missing_citations = count(con, "exceptions") - int(
                con.execute(
                    "SELECT COUNT(*) FROM exceptions "
                    "WHERE source_url LIKE 'http://%' OR source_url LIKE 'https://%'"
                ).fetchone()[0]
            )
            if missing_citations:
                failures.append(f"exceptions has {missing_citations} row(s) without an http(s) citation")

        try:
            con.execute(
                "SELECT b.brand_name, b.parent, b.is_target "
                "FROM barcodes bc JOIN brands b ON bc.brand_slug = b.brand_slug "
                "WHERE bc.barcode = ?",
                ("0000000000000",),
            ).fetchone()
        except sqlite3.Error as exc:
            failures.append(f"old app lookup SELECT failed: {exc}")

        if table_exists(con, "barcodes"):
            actual_counts["matched_brand_slugs"] = int(con.execute(
                "SELECT COUNT(*) FROM brands b "
                "WHERE EXISTS (SELECT 1 FROM barcodes bc WHERE bc.brand_slug = b.brand_slug)"
            ).fetchone()[0])
        if table_exists(con, "prefixes"):
            actual_counts["prefix_evidence_count"] = int(con.execute(
                "SELECT COALESCE(SUM(evidence_count), 0) FROM prefixes"
            ).fetchone()[0])

    for key, actual in actual_counts.items():
        if (key in required_manifest_keys or key in manifest) and manifest.get(key) != actual:
            failures.append(f"{key} count mismatch: manifest={manifest.get(key)!r} actual={actual!r}")

    if "brand_match_rate" in manifest:
        brands = actual_counts.get("brands", 0)
        expected_rate = round((actual_counts.get("matched_brand_slugs", 0) / brands), 4) if brands else 0.0
        if manifest.get("brand_match_rate") != expected_rate:
            failures.append(
                f"brand_match_rate mismatch: manifest={manifest.get('brand_match_rate')!r} "
                f"actual={expected_rate!r}"
            )

    if failures:
        print("Release asset verification failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    extra = ""
    if "exceptions" in actual_counts or "prefixes" in actual_counts:
        extra = f", {actual_counts.get('exceptions', 0)} exceptions, {actual_counts.get('prefixes', 0)} prefixes"
    print(
        f"PASS release assets: {actual_counts['brands']} brands, "
        f"{actual_counts['barcodes']} barcodes{extra}, version {version}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
