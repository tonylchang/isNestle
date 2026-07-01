#!/usr/bin/env python3
"""check_counts.py — refuse to publish a dataset that shrank materially.

The failure mode this guards against: a flaky source (OFF search, a Wikipedia
page-format change breaking the wikitext scraping) tends to *shrink* the built
dataset rather than error, so the daily workflow would happily publish a much
thinner dataset to every user. Compare the freshly built manifest against the
previously published one and fail if either table dropped more than the allowed
fraction.

The workflow skips this check when no previous manifest exists (first publish).

    python3 check_counts.py --previous previous_manifest.json [--current out/manifest.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import common

# Day-to-day wobble is normal (sources fluctuate a little); a drop beyond this
# fraction in either table means a source silently degraded.
MAX_SHRINK = 0.10
COUNT_KEYS = ("brands", "barcodes")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fail if the new dataset is materially smaller than the published one.")
    parser.add_argument("--previous", type=Path, required=True,
                        help="the last published manifest.json")
    parser.add_argument("--current", type=Path, default=common.OUT / "manifest.json",
                        help="the freshly built manifest.json (default: out/manifest.json)")
    parser.add_argument("--max-shrink", type=float, default=MAX_SHRINK,
                        help=f"allowed fractional drop per table (default: {MAX_SHRINK})")
    args = parser.parse_args(argv)

    previous = json.loads(args.previous.read_text(encoding="utf-8"))
    current = json.loads(args.current.read_text(encoding="utf-8"))

    failures: list[str] = []
    print(f"Shrink guard: previous={previous.get('version')} current={current.get('version')} "
          f"(max shrink {args.max_shrink:.0%})")
    for key in COUNT_KEYS:
        old = int(previous.get(key) or 0)
        new = int(current.get(key) or 0)
        floor = int(old * (1 - args.max_shrink))
        shrank = old > 0 and new < floor
        print(f"  {key:9} {old:>7} -> {new:>7}  (floor {floor})  {'FAIL' if shrank else 'ok'}")
        if shrank:
            failures.append(f"{key} shrank {old} -> {new} (allowed floor {floor})")

    if failures:
        print("\nRefusing to publish a materially smaller dataset:")
        for failure in failures:
            print(f"  - {failure}")
        print("If the drop is expected (e.g. deliberate source pruning), re-run "
              "with a higher --max-shrink or publish manually.")
        return 1
    print("PASS dataset counts are within tolerance of the previous release")
    return 0


if __name__ == "__main__":
    sys.exit(main())
