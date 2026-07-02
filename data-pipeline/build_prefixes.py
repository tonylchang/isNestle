#!/usr/bin/env python3
"""Infer conservative target manufacturer prefixes from dump evidence.

The input corpus is intentionally license-clean: exact target barcodes collected
from OFF-family dumps plus non-target dump rows as counter-evidence. A prefix is
accepted only when it has enough target evidence and zero counter-evidence.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path

import common
import rules


PREFIX_COLUMNS = ("prefix", "parent", "is_target", "evidence_count", "source")
PREFIX_LENGTHS = range(6, 11)
MIN_TARGET = 10


@dataclass(frozen=True)
class PrefixCandidate:
    prefix: str
    target_count: int
    other_count: int


def hard_excluded_prefix(prefix: str) -> bool:
    """True for restricted/internal/book/coupon-style ranges."""
    if not prefix:
        return True
    if prefix.startswith(("2", "02", "04", "978", "979", "05", "99")):
        return True
    # UPC-A ranges after GTIN-13 zero-padding.
    if prefix.startswith("0") and len(prefix) >= 3 and prefix[1:3] in {"02", "04", "05"}:
        return True
    return False


def prefix_blocked_by_exception(prefix: str, exception_rules: list[rules.ExceptionRule]) -> bool:
    for rule in exception_rules:
        if rule.scope_type != "prefix":
            continue
        scope = rule.scope_value
        variants = {scope}
        if len(scope) < 13:
            variants.add("0" + scope)
        for variant in variants:
            if prefix.startswith(variant) or variant.startswith(prefix):
                return True
    return False


def load_target_barcodes(path: Path) -> set[str]:
    if not path.exists():
        return set()
    out: set[str] = set()
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if (row.get("maker_override") or "").strip():
                continue
            basis = (row.get("match_basis") or "exact").strip() or "exact"
            if basis != "exact":
                continue
            gtin = common.normalize_gtin13(row.get("barcode") or "")
            if gtin and not hard_excluded_prefix(gtin):
                out.add(gtin)
    return out


def load_counter_barcodes(path: Path) -> set[str]:
    if not path.exists():
        return set()
    out: set[str] = set()
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if (row.get("corpus") or "").strip() != "other":
                continue
            gtin = common.normalize_gtin13(row.get("barcode") or "")
            if gtin and not hard_excluded_prefix(gtin):
                out.add(gtin)
    return out


def count_prefixes(target_barcodes: set[str], counter_barcodes: set[str]) -> dict[str, PrefixCandidate]:
    target_counts: dict[str, int] = {}
    other_counts: dict[str, int] = {}
    for barcode in target_barcodes:
        for length in PREFIX_LENGTHS:
            prefix = barcode[:length]
            if not hard_excluded_prefix(prefix):
                target_counts[prefix] = target_counts.get(prefix, 0) + 1
    for barcode in counter_barcodes:
        for length in PREFIX_LENGTHS:
            prefix = barcode[:length]
            if not hard_excluded_prefix(prefix):
                other_counts[prefix] = other_counts.get(prefix, 0) + 1

    prefixes = set(target_counts) | set(other_counts)
    return {
        prefix: PrefixCandidate(
            prefix=prefix,
            target_count=target_counts.get(prefix, 0),
            other_count=other_counts.get(prefix, 0),
        )
        for prefix in prefixes
    }


def accepted_prefixes(
    candidates: dict[str, PrefixCandidate],
    exception_rules: list[rules.ExceptionRule],
    *,
    min_target: int = MIN_TARGET,
) -> list[PrefixCandidate]:
    accepted = [
        candidate
        for candidate in candidates.values()
        if candidate.target_count >= min_target
        and candidate.other_count == 0
        and not hard_excluded_prefix(candidate.prefix)
        and not prefix_blocked_by_exception(candidate.prefix, exception_rules)
    ]

    longest: list[PrefixCandidate] = []
    for candidate in sorted(accepted, key=lambda c: (-len(c.prefix), c.prefix)):
        if any(existing.prefix.startswith(candidate.prefix) for existing in longest):
            continue
        longest.append(candidate)
    return sorted(longest, key=lambda c: c.prefix)


def write_prefixes(path: Path, prefixes: list[PrefixCandidate]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(PREFIX_COLUMNS)
        for prefix in prefixes:
            writer.writerow([prefix.prefix, common.PARENT_DEFAULT, 1, prefix.target_count, "prefix-inference"])


def _read_known_slugs(path: Path) -> set[str]:
    if not path.exists():
        return set()
    with open(path, newline="", encoding="utf-8") as fh:
        return {(row.get("brand_slug") or "").strip() for row in csv.DictReader(fh) if (row.get("brand_slug") or "").strip()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build conservative target barcode prefixes.")
    parser.add_argument("--barcodes", type=Path, default=common.BARCODES_CSV,
                        help="barcodes CSV (default: out/barcodes.csv)")
    parser.add_argument("--corpus", type=Path, default=common.PREFIX_CORPUS_CSV,
                        help="counter-evidence corpus from dump mode")
    parser.add_argument("--output", type=Path, default=common.PREFIXES_CSV,
                        help="prefixes CSV to write")
    parser.add_argument("--min-target", type=int, default=MIN_TARGET,
                        help=f"minimum target barcodes under a prefix (default: {MIN_TARGET})")
    args = parser.parse_args(argv)

    known_slugs = _read_known_slugs(common.BRANDS_CSV)
    exception_rules = rules.read_exception_rules(common.EXCEPTIONS_CSV, known_slugs or None)
    target = load_target_barcodes(args.barcodes)
    counter = load_counter_barcodes(args.corpus)

    if not counter:
        print(f"WARNING: no counter-evidence rows in {args.corpus}; writing zero prefixes")
        write_prefixes(args.output, [])
        return 0

    candidates = count_prefixes(target, counter)
    prefixes = accepted_prefixes(candidates, exception_rules, min_target=args.min_target)
    write_prefixes(args.output, prefixes)

    evidence = sum(p.target_count for p in prefixes)
    print(f"build_prefixes.py")
    print(f"  target barcodes:     {len(target)}")
    print(f"  counter barcodes:    {len(counter)}")
    print(f"  accepted prefixes:   {len(prefixes)}")
    print(f"  prefix evidence sum: {evidence}")
    print(f"  wrote: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
