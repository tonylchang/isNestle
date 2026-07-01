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


def count(con: sqlite3.Connection, table: str) -> int:
    return int(con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


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

    with sqlite3.connect(args.db) as con:
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            failures.append(f"SQLite integrity_check failed: {integrity}")

        fk_errors = con.execute("PRAGMA foreign_key_check").fetchall()
        if fk_errors:
            failures.append(f"SQLite foreign_key_check found {len(fk_errors)} violation(s)")

        actual_counts = {"brands": count(con, "brands"), "barcodes": count(con, "barcodes")}

    for key, actual in actual_counts.items():
        if manifest.get(key) != actual:
            failures.append(f"{key} count mismatch: manifest={manifest.get(key)!r} actual={actual!r}")

    if failures:
        print("Release asset verification failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"PASS release assets: {actual_counts['brands']} brands, {actual_counts['barcodes']} barcodes, version {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
