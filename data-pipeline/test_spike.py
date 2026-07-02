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

# Real NON-Nestlé barcodes that must NEVER resolve as a Nestlé match.
#   - Coca-Cola: an unrelated competitor (brands_tags == ['coca-cola']).
#   - L'Oréal: Nestlé holds only a MINORITY stake — its products are not "made
#     by Nestlé." These guard the WDQS-outage failure mode where the pipeline
#     would otherwise import the whole L'Oréal/Sanofi/Alcon closure as false
#     Nestlé brands (see build_brands.fetch_wikidata / DENY_SLUGS).
NON_NESTLE = ("7702535016688", "Coca-Cola Fuze Tea (coca-cola)")
NON_NESTLE_ANCHORS = [
    ("7702535016688", "Coca-Cola Fuze Tea (competitor)"),
    ("0065338054743", "L'Oréal Paris (Nestlé minority stake, not a subsidiary)"),
    ("3600523970177", "L'Oréal Paris Elvive (minority stake)"),
]

# Offline W3 anchors: the curated false-positive rules must be shipped in SQLite.
EXPECTED_EXCEPTIONS = [
    ("kitkat", "co_brand", "hershey-s", "reattribute"),
    ("kit-kat", "co_brand", "hershey-s", "reattribute"),
    ("crunch", "country", "en:united-states", "reattribute"),
    ("nestle-crunch", "country", "en:united-states", "reattribute"),
    ("smarties", "country", "en:united-states", "exclude"),
]


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

    print("\n== Additive schema compatibility ==")
    tables = {
        row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    for table in ("brands", "barcodes", "exceptions", "prefixes"):
        if table in tables:
            print(f"  PASS  table exists: {table}")
        else:
            print(f"  FAIL  missing table: {table}")
            failures.append(f"missing table {table}")
    barcode_columns = {row[1] for row in conn.execute("PRAGMA table_info(barcodes)")}
    for column in ("barcode", "brand_slug", "source", "maker_override", "override_note", "match_basis", "evidence_count"):
        if column not in barcode_columns:
            failures.append(f"barcodes missing column {column}")
    try:
        conn.execute(
            "SELECT b.brand_name, b.parent, b.is_target "
            "FROM barcodes bc JOIN brands b ON bc.brand_slug = b.brand_slug "
            "WHERE bc.barcode = ?",
            ("0000000000000",),
        ).fetchone()
        print("  PASS  old app lookup SELECT still prepares")
    except sqlite3.Error as exc:
        print(f"  FAIL  old app lookup SELECT failed: {exc}")
        failures.append(f"old app lookup SELECT failed: {exc}")

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

    # --- Negative: non-Nestlé barcodes must NOT resolve as a match -----------
    # A match here means either a competitor leaked in or (the L'Oréal anchors)
    # the WDQS-outage contamination shipped. Either is a hard failure.
    print("\n== Non-Nestlé barcodes (expect no match) ==")
    for barcode, desc in NON_NESTLE_ANCHORS:
        row = lookup(conn, barcode)
        if row is None:
            print(f"  PASS  {barcode}  -> Unknown   [{desc}]")
        elif int(row[2]) == 1:
            print(f"  FAIL  {barcode}  -> {row[0]} / {row[1]}   [{desc}] (should NOT be a target match)")
            failures.append(f"non-Nestlé barcode {barcode} matched target {row[1]} (brand {row[0]}) — [{desc}]")
        else:
            # Present but explicitly not-target (e.g. a reattributed exception) is fine.
            print(f"  PASS  {barcode}  -> {row[0]} / {row[1]} / is_target={row[2]}   [{desc}]")

    # --- W3 false-positive curation rules are present in the shipped DB ------
    print("\n== False-positive curation rules (expect cited seed rules) ==")
    for brand_slug, scope_type, scope_value, action in EXPECTED_EXCEPTIONS:
        row = conn.execute(
            "SELECT actual_maker, note, source_url FROM exceptions "
            "WHERE brand_slug = ? AND scope_type = ? AND scope_value = ? AND action = ?",
            (brand_slug, scope_type, scope_value, action),
        ).fetchone()
        label = f"{brand_slug}/{scope_type}:{scope_value}/{action}"
        if row and row[1] and str(row[2]).startswith("https://"):
            print(f"  PASS  {label}  -> source={row[2]}")
        else:
            print(f"  FAIL  missing or uncited exception rule: {label}")
            failures.append(f"missing or uncited exception rule: {label}")

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
    n_exceptions = conn.execute("SELECT COUNT(*) FROM exceptions").fetchone()[0]
    n_prefixes = conn.execute("SELECT COUNT(*) FROM prefixes").fetchone()[0]
    rate = (matched / total_slugs * 100.0) if total_slugs else 0.0
    print(f"  brand_slugs with >=1 OFF barcode: {matched}/{total_slugs} ({rate:.0f}%)")
    print(f"  total barcodes in dataset:        {n_barcodes}")
    print(f"  exception rules in dataset:       {n_exceptions}")
    print(f"  accepted prefixes in dataset:     {n_prefixes}")
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
