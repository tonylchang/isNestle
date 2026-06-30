#!/usr/bin/env python3
"""test_spike.py — THE Milestone-0 validation for isNestle (Agent B).

Loads ``out/isnestle.sqlite`` and asserts the spike's done-criterion:
  * several real, KNOWN Nestlé barcodes resolve to parent='Nestlé', is_target=1;
  * a clearly NON-Nestlé barcode (Coca-Cola) returns no match ("Unknown").

Also prints the key spike finding: the brand-name **normalization match-rate** —
how many brand_slugs actually returned barcodes from OFF, and which returned zero.

Prints PASS/FAIL and exits non-zero on FAIL. Run:
    python3 test_spike.py
"""
from __future__ import annotations

import sqlite3
import sys

import common

# Real Nestlé barcodes CONFIRMED to exist via Search-a-licious during development.
# Chosen from low-count brands (milkybar=7, aero=16 products) so they are fully
# captured under the build_barcodes spike cap (25/brand) and reliably land in the DB.
# Each carries 'nestle' in its OFF brands_tags.
KNOWN_NESTLE = [
    ("7613287012449", "Milkybar (nestle, milkybar)"),
    ("8445290461803", "Milkybar (milkybar, nestle)"),
    ("3023290000953", "Aero (aero, nestle)"),
    ("7613039869048", "Aero (aero, nestle)"),
    ("7613034599612", "Aero Peppermint (nestle, aero)"),
    ("0059800745901", "Aero (aero, nestle)"),
]
# Require at least this many of the above to resolve (resilient to OFF data drift).
MIN_NESTLE_PASS = 3
MIN_BRANDS = 500
MIN_MATCHED_BRAND_SLUGS = 250
MIN_BARCODES = 10000

# Real NON-Nestlé barcode CONFIRMED via Search-a-licious: brands_tags == ['coca-cola'].
NON_NESTLE = ("7702535016688", "Coca-Cola Fuze Tea (coca-cola)")


def lookup(conn: sqlite3.Connection, barcode: str):
    """Scan-time lookup: barcode -> (brand_name, parent, is_target) or None."""
    return conn.execute(
        "SELECT b.brand_name, b.parent, b.is_target "
        "FROM barcodes bc JOIN brands b ON bc.brand_slug = b.brand_slug "
        "WHERE bc.barcode = ?",
        (barcode,),
    ).fetchone()


def main() -> int:
    if not common.SQLITE_DB.exists():
        print(f"FAIL: {common.SQLITE_DB} not found — run build_barcodes.py then build_db.py.")
        return 1

    conn = sqlite3.connect(common.SQLITE_DB)
    failures: list[str] = []

    print("== SQLite integrity ==")
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity == "ok":
        print("  PASS  PRAGMA integrity_check -> ok")
    else:
        print(f"  FAIL  PRAGMA integrity_check -> {integrity}")
        failures.append(f"sqlite integrity_check failed: {integrity}")

    fk_errors = conn.execute("PRAGMA foreign_key_check").fetchall()
    if not fk_errors:
        print("  PASS  PRAGMA foreign_key_check -> no orphaned rows")
    else:
        print(f"  FAIL  PRAGMA foreign_key_check -> {len(fk_errors)} violation(s)")
        failures.append(f"sqlite foreign_key_check found {len(fk_errors)} violation(s)")

    # --- Positive: known Nestlé barcodes resolve to Nestlé -------------------
    print("\n== Known Nestlé barcodes (expect parent='Nestlé', is_target=1) ==")
    nestle_pass = 0
    for barcode, desc in KNOWN_NESTLE:
        row = lookup(conn, barcode)
        if row and row[1] == common.PARENT_DEFAULT and int(row[2]) == 1:
            nestle_pass += 1
            print(f"  PASS  {barcode}  -> {row[0]} / {row[1]} / is_target={row[2]}   [{desc}]")
        elif row:
            print(f"  WARN  {barcode}  -> {row[0]} / {row[1]} / is_target={row[2]}   [{desc}]")
        else:
            print(f"  miss  {barcode}  -> Unknown (not collected this run)   [{desc}]")
    if nestle_pass < MIN_NESTLE_PASS:
        failures.append(
            f"only {nestle_pass}/{len(KNOWN_NESTLE)} known Nestlé barcodes resolved "
            f"(need >= {MIN_NESTLE_PASS})"
        )

    # --- Negative: a non-Nestlé barcode must NOT match -----------------------
    print("\n== Non-Nestlé barcode (expect Unknown / no match) ==")
    barcode, desc = NON_NESTLE
    row = lookup(conn, barcode)
    if row is None:
        print(f"  PASS  {barcode}  -> Unknown   [{desc}]")
    else:
        print(f"  FAIL  {barcode}  -> {row[0]} / {row[1]}   [{desc}] (should be Unknown)")
        failures.append(f"non-Nestlé barcode {barcode} unexpectedly matched {row[1]}")

    # --- KEY SPIKE FINDING: normalization match-rate report ------------------
    print("\n== Normalization match-rate report ==")
    total_slugs = conn.execute("SELECT COUNT(*) FROM brands").fetchone()[0]
    matched = conn.execute(
        "SELECT COUNT(*) FROM brands b "
        "WHERE EXISTS (SELECT 1 FROM barcodes bc WHERE bc.brand_slug = b.brand_slug)"
    ).fetchone()[0]
    zero_hits = [
        r[0] for r in conn.execute(
            "SELECT b.brand_slug FROM brands b "
            "WHERE NOT EXISTS (SELECT 1 FROM barcodes bc WHERE bc.brand_slug = b.brand_slug) "
            "ORDER BY b.brand_slug"
        )
    ]
    n_barcodes = conn.execute("SELECT COUNT(*) FROM barcodes").fetchone()[0]
    rate = (matched / total_slugs * 100.0) if total_slugs else 0.0
    print(f"  brand_slugs with >=1 OFF barcode: {matched}/{total_slugs} ({rate:.0f}%)")
    print(f"  total barcodes in dataset:        {n_barcodes}")
    if total_slugs < MIN_BRANDS:
        failures.append(f"brand count is {total_slugs}, expected at least {MIN_BRANDS}")
    if matched < MIN_MATCHED_BRAND_SLUGS:
        failures.append(
            f"only {matched} brand slugs have barcodes, expected at least {MIN_MATCHED_BRAND_SLUGS}"
        )
    if n_barcodes < MIN_BARCODES:
        failures.append(f"barcode count is {n_barcodes}, expected at least {MIN_BARCODES}")
    if zero_hits:
        print(f"  ZERO-hit slugs (normalization misses, {len(zero_hits)}): {', '.join(zero_hits)}")
    else:
        print("  ZERO-hit slugs: none — every brand_slug reconciled to an OFF tag.")

    conn.close()

    # --- Verdict -------------------------------------------------------------
    print("\n" + "=" * 60)
    if failures:
        print("RESULT: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"RESULT: PASS  ({nestle_pass}/{len(KNOWN_NESTLE)} Nestlé barcodes matched, "
          f"negative control returned Unknown)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
