#!/usr/bin/env python3
"""Collect target-company barcodes from OFF-family data.

Default mode streams the OFF-family TSV dumps with stdlib-only Python and keeps
the older API search path as an explicit fallback:

    python3 build_barcodes.py                  # dump mode, API fallback on failure
    python3 build_barcodes.py --mode api       # lightweight legacy path

Output ``out/barcodes.csv`` keeps the old columns intact and adds nullable
columns that old app binaries ignore:

    barcode,brand_slug,source,maker_override,override_note,match_basis,evidence_count
"""
from __future__ import annotations

import argparse
import csv
import gzip
import io
import sys
import time
import urllib.request
from dataclasses import dataclass

import common
import rules


RESULT_WINDOW = 10000
SLEEP_SECONDS = 0.4

BARCODE_COLUMNS = (
    "barcode",
    "brand_slug",
    "source",
    "maker_override",
    "override_note",
    "match_basis",
    "evidence_count",
)
PREFIX_CORPUS_COLUMNS = ("barcode", "source", "corpus")

DATASETS = [
    {
        "id": "off",
        "name": "Open Food Facts",
        "kind": "salicious",
        "url": common.OFF_SEARCH_URL,
        "dump_url": "https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz",
    },
    {
        "id": "opff",
        "name": "Open Pet Food Facts",
        "kind": "v2",
        "url": common.OPFF_SEARCH_URL,
        "dump_url": "https://static.openpetfoodfacts.org/data/openpetfoodfacts-products.csv.gz",
    },
    {
        "id": "obf",
        "name": "Open Beauty Facts",
        "kind": "v2",
        "url": common.OBF_SEARCH_URL,
        "dump_url": "https://static.openbeautyfacts.org/data/openbeautyfacts-products.csv.gz",
    },
    {
        "id": "opf",
        "name": "Open Products Facts",
        "kind": "v2",
        "url": common.OPF_SEARCH_URL,
        "dump_url": "https://static.openproductsfacts.org/data/openproductsfacts-products.csv.gz",
    },
]
DATASETS_BY_ID = {d["id"]: d for d in DATASETS}
PAGE_SIZE_BY_KIND = {"salicious": 250, "v2": 100}
OWNER_FIELDS = ("owner", "brand_owner", "owners", "owners_tags")


@dataclass(frozen=True)
class BarcodeCandidate:
    barcode: str
    brand_slug: str
    source: str
    brands_tags: list[str]
    countries_tags: list[str]
    owner: str = ""


def _set_csv_field_limit() -> None:
    limit = common.CSV_FIELD_SIZE_LIMIT
    while True:
        try:
            csv.field_size_limit(limit)
            return
        except OverflowError:
            limit = int(limit / 10)


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


def _owner_from_row(row: dict) -> str:
    for field in OWNER_FIELDS:
        value = (row.get(field) or "").strip()
        if value:
            return value
    return ""


def select_target_slug(brands_tags: list[str], slug_priority: dict[str, int]) -> str | None:
    matches = [tag for tag in brands_tags if tag in slug_priority]
    if not matches:
        return None
    return min(matches, key=lambda slug: slug_priority[slug])


def candidate_from_product_row(row: dict, slug_priority: dict[str, int], source: str) -> BarcodeCandidate | None:
    """Return a target match from one OFF row, or None for no exact target slug."""
    barcode = (row.get("code") or row.get("barcode") or row.get("_id") or "").strip()
    if not barcode:
        return None
    brands_tags = common.parse_tag_list(row.get("brands_tags") or row.get("brands") or "")
    brand_slug = select_target_slug(brands_tags, slug_priority)
    if not brand_slug:
        return None
    return BarcodeCandidate(
        barcode=barcode,
        brand_slug=brand_slug,
        source=source,
        brands_tags=brands_tags,
        countries_tags=common.parse_tag_list(row.get("countries_tags") or row.get("countries") or ""),
        owner=_owner_from_row(row),
    )


def row_has_any_brand_data(row: dict) -> bool:
    return bool((row.get("code") or row.get("barcode") or row.get("_id") or "").strip())


def row_is_counter_evidence(row: dict, target_slugs: set[str]) -> bool:
    """True when a dump row has brand tags but none are target slugs."""
    if not row_has_any_brand_data(row):
        return False
    brands_tags = common.parse_tag_list(row.get("brands_tags") or row.get("brands") or "")
    return bool(brands_tags) and not (set(brands_tags) & target_slugs)


def apply_rules_to_candidate(
    candidate: BarcodeCandidate,
    exception_rules: list[rules.ExceptionRule],
) -> tuple[tuple[str, str, str, str, str, str, str] | None, str]:
    """Return (barcode CSV row or None, corpus kind target/other)."""
    application = rules.apply_exception_rules(
        candidate.brand_slug,
        candidate.barcode,
        candidate.brands_tags,
        candidate.countries_tags,
        exception_rules,
    )
    if application and application.action == "exclude":
        return None, "other"

    maker_override = application.actual_maker if application and application.action == "reattribute" else ""
    override_note = application.note if application and application.action == "reattribute" else ""
    corpus = "other" if maker_override else "target"
    return (
        (
            candidate.barcode,
            candidate.brand_slug,
            candidate.source,
            maker_override,
            override_note,
            "exact",
            "1",
        ),
        corpus,
    )


def fetch_for_slug(slug: str, dataset: dict) -> tuple[list[BarcodeCandidate], int]:
    """Return target barcode candidates for one slug from one API dataset."""
    kind = dataset["kind"]
    url = dataset["url"]
    page_size = PAGE_SIZE_BY_KIND[kind]
    results_key = "hits" if kind == "salicious" else "products"
    source = f"{dataset['id']}-api"

    candidates: list[BarcodeCandidate] = []
    total = 0
    page = 1
    while True:
        fields = "code,brands_tags,countries_tags,owner,brand_owner,owners,owners_tags"
        if kind == "salicious":
            params = {"q": f"brands_tags:{slug}", "fields": fields,
                      "page_size": page_size, "page": page}
        else:
            params = {"brands_tags": slug, "fields": fields,
                      "page_size": page_size, "page": page}
        data = common.http_get_json(url, params)
        if page == 1:
            total = int(data.get("count") or 0)
        hits = data.get(results_key) or []
        if not hits:
            break
        priority = {slug: 0}
        for hit in hits:
            candidate = candidate_from_product_row(hit, priority, source)
            if candidate and candidate.brand_slug == slug:
                candidates.append(candidate)
        fetched = page * page_size
        if fetched >= total or fetched >= RESULT_WINDOW:
            break
        page += 1
        time.sleep(SLEEP_SECONDS)
    return candidates, total


def run_dataset_api(
    dataset: dict,
    slugs: list[str],
    collected: dict[str, tuple[str, str, str, str, str, str, str]],
    exception_rules: list[rules.ExceptionRule],
) -> dict:
    src = dataset["id"]
    print(f"\n[{src}] {dataset['name']} API ({dataset['kind']})")
    kept_total = 0
    new_total = 0
    slugs_with_hits = 0
    zero_hits: list[str] = []
    excluded = 0
    reattributed = 0

    for slug in slugs:
        try:
            candidates, total = fetch_for_slug(slug, dataset)
        except Exception as exc:  # noqa: BLE001
            print(f"  {slug:24} ERROR {exc!r}")
            zero_hits.append(slug)
            time.sleep(SLEEP_SECONDS)
            continue

        new = 0
        for candidate in candidates:
            row, _corpus = apply_rules_to_candidate(candidate, exception_rules)
            if row is None:
                excluded += 1
                continue
            if row[3]:
                reattributed += 1
            if row[0] not in collected:
                collected[row[0]] = row
                new += 1
        kept_total += len(candidates)
        new_total += new
        if candidates:
            slugs_with_hits += 1
            capped = " (window-capped)" if total > RESULT_WINDOW else ""
            print(f"  {slug:24} total={total:>6}  kept={len(candidates):>4}  new={new:>4}{capped}")
        else:
            zero_hits.append(slug)
        time.sleep(SLEEP_SECONDS)

    print(f"  -> {new_total} new barcodes from {slugs_with_hits}/{len(slugs)} slugs")
    return {
        "id": src,
        "mode": "api",
        "kept": kept_total,
        "new": new_total,
        "slugs_with_hits": slugs_with_hits,
        "zero_hits": zero_hits,
        "excluded": excluded,
        "reattributed": reattributed,
    }


def _open_dump_text(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": common.USER_AGENT})
    response = urllib.request.urlopen(req, timeout=120)
    gz = gzip.GzipFile(fileobj=response)
    return io.TextIOWrapper(gz, encoding="utf-8", newline="")


def _validate_dump_header(dataset_id: str, fieldnames: list[str] | None) -> None:
    fields = set(fieldnames or [])
    missing = {"code", "brands_tags"} - fields
    if missing:
        raise RuntimeError(f"{dataset_id} dump missing required column(s): {', '.join(sorted(missing))}")


def run_dataset_dump(
    dataset: dict,
    slug_priority: dict[str, int],
    collected: dict[str, tuple[str, str, str, str, str, str, str]],
    exception_rules: list[rules.ExceptionRule],
    corpus_writer: csv.writer,
) -> dict:
    dataset_id = dataset["id"]
    source = f"{dataset_id}-dump"
    target_slugs = set(slug_priority)
    rows_seen = 0
    target_rows = 0
    new_total = 0
    counter_rows = 0
    excluded = 0
    reattributed = 0

    print(f"\n[{dataset_id}] {dataset['name']} dump")
    with _open_dump_text(dataset["dump_url"]) as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        _validate_dump_header(dataset_id, reader.fieldnames)
        for row in reader:
            rows_seen += 1
            barcode = (row.get("code") or "").strip()
            if row_is_counter_evidence(row, target_slugs):
                corpus_writer.writerow([barcode, source, "other"])
                counter_rows += 1
                continue

            candidate = candidate_from_product_row(row, slug_priority, source)
            if candidate is None:
                continue
            target_rows += 1
            out_row, corpus = apply_rules_to_candidate(candidate, exception_rules)
            corpus_writer.writerow([candidate.barcode, source, corpus])
            if out_row is None:
                excluded += 1
                continue
            if out_row[3]:
                reattributed += 1
            if out_row[0] not in collected:
                collected[out_row[0]] = out_row
                new_total += 1

    print(f"  rows={rows_seen} target_rows={target_rows} counter_rows={counter_rows} new={new_total}")
    return {
        "id": dataset_id,
        "mode": "dump",
        "kept": target_rows,
        "new": new_total,
        "slugs_with_hits": 0,
        "zero_hits": [],
        "excluded": excluded,
        "reattributed": reattributed,
        "counter_rows": counter_rows,
    }


def write_barcodes(rows_by_barcode: dict[str, tuple[str, str, str, str, str, str, str]]) -> None:
    with open(common.BARCODES_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(BARCODE_COLUMNS)
        for barcode in sorted(rows_by_barcode):
            writer.writerow(rows_by_barcode[barcode])


def run_api_pipeline(
    selected: list[dict],
    slugs: list[str],
    exception_rules: list[rules.ExceptionRule],
) -> tuple[dict[str, tuple[str, str, str, str, str, str, str]], list[dict]]:
    collected: dict[str, tuple[str, str, str, str, str, str, str]] = {}
    # Prefix inference requires all-product counter-evidence; API mode cannot
    # produce that, so leave a clear empty corpus file.
    with open(common.PREFIX_CORPUS_CSV, "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerow(PREFIX_CORPUS_COLUMNS)
    stats = [run_dataset_api(d, slugs, collected, exception_rules) for d in selected]
    return collected, stats


def run_dump_pipeline(
    selected: list[dict],
    slugs: list[str],
    exception_rules: list[rules.ExceptionRule],
    *,
    api_fallback: bool = True,
) -> tuple[dict[str, tuple[str, str, str, str, str, str, str]], list[dict]]:
    collected: dict[str, tuple[str, str, str, str, str, str, str]] = {}
    slug_priority = {slug: idx for idx, slug in enumerate(slugs)}
    stats: list[dict] = []
    with open(common.PREFIX_CORPUS_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(PREFIX_CORPUS_COLUMNS)
        for dataset in selected:
            try:
                stats.append(run_dataset_dump(dataset, slug_priority, collected, exception_rules, writer))
            except Exception as exc:  # noqa: BLE001 - per-dataset degradation is intentional
                if not api_fallback:
                    raise
                print(
                    f"::warning::{dataset['id']} dump failed ({exc!r}); "
                    "falling back to API mode for this dataset"
                )
                stat = run_dataset_api(dataset, slugs, collected, exception_rules)
                stat["fallback_from"] = "dump"
                stat["fallback_error"] = repr(exc)
                stats.append(stat)
    return collected, stats


def _selected_datasets(ids_arg: str) -> list[dict]:
    ids = [s.strip() for s in ids_arg.split(",") if s.strip()]
    unknown = [i for i in ids if i not in DATASETS_BY_ID]
    if unknown:
        raise ValueError(
            f"unknown dataset id(s): {', '.join(unknown)}; known ids: {', '.join(DATASETS_BY_ID)}"
        )
    return [DATASETS_BY_ID[i] for i in ids]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect OFF-family barcodes for known brand slugs.")
    parser.add_argument("--brands", default=str(common.BRANDS_CSV),
                        help="path to brands CSV (default: out/brands.csv)")
    parser.add_argument("--datasets", default=",".join(d["id"] for d in DATASETS),
                        help="comma-separated dataset ids to query")
    parser.add_argument("--mode", choices=("dump", "api"), default="dump",
                        help="data source mode (default: dump)")
    parser.add_argument("--no-api-fallback", action="store_true",
                        help="in dump mode, fail instead of falling back to API mode")
    args = parser.parse_args(argv)

    try:
        selected = _selected_datasets(args.datasets)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    try:
        slugs = read_brand_slugs(args.brands)
    except FileNotFoundError:
        print(f"ERROR: brands file not found: {args.brands}", file=sys.stderr)
        return 2
    if not slugs:
        print(f"ERROR: no brand_slug values in {args.brands}", file=sys.stderr)
        return 2

    common.ensure_out()
    _set_csv_field_limit()
    try:
        exception_rules = rules.read_exception_rules(common.EXCEPTIONS_CSV, set(slugs))
    except rules.RuleError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    print(f"OFF-family barcode pipeline: {len(slugs)} brand slugs from {args.brands}")
    print(f"datasets: {', '.join(d['id'] for d in selected)}")
    print(f"mode: {args.mode}")
    print(f"exception rules: {len(exception_rules)}")

    try:
        if args.mode == "api":
            collected, stats = run_api_pipeline(selected, slugs, exception_rules)
        else:
            collected, stats = run_dump_pipeline(
                selected,
                slugs,
                exception_rules,
                api_fallback=not args.no_api_fallback,
            )
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {args.mode} mode failed: {exc!r}", file=sys.stderr)
        return 1

    write_barcodes(collected)

    print(f"\n{'=' * 60}")
    print(f"Wrote {len(collected)} unique barcodes -> {common.BARCODES_CSV}")
    print(f"Prefix corpus -> {common.PREFIX_CORPUS_CSV}")
    for st in stats:
        suffix = ""
        if st.get("excluded") or st.get("reattributed"):
            suffix = f" (excluded={st.get('excluded', 0)}, reattributed={st.get('reattributed', 0)})"
        print(f"  {st['id']:5} {st['mode']:4} contributed {st['new']:>6} barcodes{suffix}")

    off_stat = next((s for s in stats if s["id"] == "off" and s["mode"] == "api"), None)
    if off_stat and off_stat["zero_hits"]:
        misses = off_stat["zero_hits"]
        shown = ", ".join(misses[:30]) + (" ..." if len(misses) > 30 else "")
        print(f"\nOFF normalization misses ({len(misses)} slugs with zero OFF hits): {shown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
