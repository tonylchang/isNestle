#!/usr/bin/env python3
"""build_manifest.py — emit out/manifest.json describing the built SQLite.

The manifest is what the app checks to decide whether to self-update. It is
published to GitHub Releases alongside isnestle.sqlite (see the dataset workflow),
and a copy is bundled in the app as the install-time baseline.

Version is a UTC CalVer timestamp (YYYY.MM.DD.HHMM); pass it in (CI uses the run
time) or it defaults to now.

    python3 build_manifest.py [--version 2026.06.28.0617]
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import sqlite3

import common

# Where the published assets live (rolling release; see VERSIONING.md / INFRA.md).
RELEASE_BASE = "https://github.com/tonylchang/isNestle/releases/download/dataset-latest"
MANIFEST_PATH = common.OUT / "manifest.json"


def _count(con: sqlite3.Connection, table: str) -> int:
    return int(con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build the dataset manifest.")
    default_version = _dt.datetime.now(_dt.timezone.utc).strftime("%Y.%m.%d.%H%M")
    parser.add_argument("--version", default=default_version,
                        help="UTC dataset version (default: now, YYYY.MM.DD.HHMM)")
    args = parser.parse_args(argv)

    db = common.SQLITE_DB
    if not db.exists():
        print(f"ERROR: {db} not found — run build_db.py first")
        return 2

    data = db.read_bytes()
    with sqlite3.connect(db) as con:
        brands, barcodes = _count(con, "brands"), _count(con, "barcodes")

    manifest = {
        "version": args.version,
        "sqlite_url": f"{RELEASE_BASE}/isnestle.sqlite",
        "sqlite_sha256": hashlib.sha256(data).hexdigest(),
        "sqlite_bytes": len(data),
        "brands": brands,
        "barcodes": barcodes,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {MANIFEST_PATH}")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
