#!/usr/bin/env python3
"""Reconcile generated brand slugs against OFF-family brand facets.

Run after ``build_brands.py`` and before barcode collection:

    python3 reconcile_brands.py

The script is deliberately conservative:
  * reviewed aliases from ``aliases.csv`` are merged into ``out/brands.csv``;
  * generated candidates are auto-added only when they exactly appear in an
    OFF-family facet vocabulary;
  * fuzzy matches are written to ``out/alias_review.txt`` for human review and
    never become data by themselves.
"""
from __future__ import annotations

import argparse
import csv
import difflib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import common


ALIAS_COLUMNS = ("alias_slug", "canonical_slug", "note")

KNOWN_NON_TARGET_TAGS = {
    "hershey-s",
    "coca-cola",
    "mondelez",
    "mars",
    "ferrero",
    "smarties",
    "smarties-candy-company",
}

CORPORATE_SUFFIXES = {
    "co",
    "company",
    "corp",
    "corporation",
    "inc",
    "gmbh",
    "sa",
    "ag",
    "ltd",
    "llc",
    "plc",
}

FACET_DATASETS = [
    ("off", "https://world.openfoodfacts.org/brands.json"),
    ("opff", "https://world.openpetfoodfacts.org/brands.json"),
    ("obf", "https://world.openbeautyfacts.org/brands.json"),
    ("opf", "https://world.openproductsfacts.org/brands.json"),
]


class AliasError(ValueError):
    """Raised when alias inputs would make the generated dataset unsafe."""


@dataclass(frozen=True)
class BrandRow:
    brand_slug: str
    brand_name: str
    parent: str
    is_target: int


@dataclass(frozen=True)
class FacetTag:
    slug: str
    products: int
    dataset: str


def generate_alias_candidates(slug: str) -> set[str]:
    """Generate mechanical spelling variants for one canonical brand slug."""
    slug = common.off_slug(slug)
    if not slug:
        return set()

    candidates: set[str] = set()
    parts = [p for p in slug.split("-") if p]

    if "-" in slug:
        candidates.add(slug.replace("-", ""))
        if parts[-1:] and parts[-1] in CORPORATE_SUFFIXES and len(parts) > 1:
            candidates.add("-".join(parts[:-1]))
    elif 4 <= len(slug) <= 24:
        # Reverse of hyphen-collapse. This is intentionally broad, but only
        # exact facet hits can pass through to data.
        for i in range(2, len(slug) - 1):
            candidates.add(f"{slug[:i]}-{slug[i:]}")

    if slug.endswith("-s"):
        candidates.add(slug[:-2] + "s")
    elif slug.endswith("s") and len(slug) > 3:
        candidates.add(slug[:-1] + "-s")

    if "-and-" in slug:
        candidates.add(slug.replace("-and-", "-"))
    else:
        for i in range(1, len(parts)):
            candidates.add("-".join(parts[:i] + ["and"] + parts[i:]))

    if not slug.startswith("nestle-") and slug != "nestle":
        candidates.add(f"nestle-{slug}")

    candidates.discard(slug)
    candidates.discard("")
    return candidates


def _facet_slug(raw: object) -> str:
    value = str(raw or "").strip()
    if not value:
        return ""
    # Facet ids are usually plain slugs, but some endpoints include language
    # prefixes or URLs. Keep the actual tag segment.
    value = value.rstrip("/").split("/")[-1]
    if ":" in value:
        value = value.split(":", 1)[1]
    return common.off_slug(value)


def parse_brand_facets(data: object, dataset: str) -> dict[str, FacetTag]:
    """Extract ``brands_tags`` vocabulary from an OFF facet JSON response."""
    if isinstance(data, dict):
        raw_tags = data.get("tags") or data.get("brands") or []
    elif isinstance(data, list):
        raw_tags = data
    else:
        raw_tags = []

    out: dict[str, FacetTag] = {}
    for item in raw_tags:
        if isinstance(item, dict):
            raw = item.get("id") or item.get("tag") or item.get("url") or item.get("name")
            products = int(item.get("products") or item.get("count") or 0)
        else:
            raw = item
            products = 0
        slug = _facet_slug(raw)
        if slug:
            out[slug] = FacetTag(slug=slug, products=products, dataset=dataset)
    return out


def fetch_or_load_facets(cache_path: Path, *, refresh: bool) -> tuple[dict[str, FacetTag], list[str]]:
    """Fetch OFF-family brand facets, falling back to the local cache if present."""
    notes: list[str] = []
    combined: dict[str, FacetTag] = {}

    if cache_path.exists() and not refresh:
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        for row in cached.get("tags", []):
            tag = FacetTag(
                slug=row["slug"],
                products=int(row.get("products") or 0),
                dataset=row.get("dataset") or "cache",
            )
            combined[tag.slug] = tag
        notes.append(f"facets: loaded {len(combined)} tags from cache {cache_path}")
        return combined, notes

    for dataset, url in FACET_DATASETS:
        try:
            data = common.http_get_json(url, timeout=60, retries=3, backoff=3.0)
            tags = parse_brand_facets(data, dataset)
            for slug, tag in tags.items():
                old = combined.get(slug)
                if old is None or tag.products > old.products:
                    combined[slug] = tag
            notes.append(f"facets: {dataset} {len(tags)} tags")
        except Exception as exc:  # noqa: BLE001 - network source is best effort
            notes.append(f"facets: {dataset} unavailable: {exc!r}")

    if combined:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(
            json.dumps(
                {"tags": [tag.__dict__ for tag in sorted(combined.values(), key=lambda t: t.slug)]},
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        notes.append(f"facets: cached {len(combined)} tags -> {cache_path}")
    return combined, notes


def read_brand_rows(path: Path) -> list[BrandRow]:
    rows: list[BrandRow] = []
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            slug = (row.get("brand_slug") or "").strip()
            if not slug:
                continue
            rows.append(
                BrandRow(
                    brand_slug=slug,
                    brand_name=(row.get("brand_name") or slug).strip(),
                    parent=(row.get("parent") or common.PARENT_DEFAULT).strip(),
                    is_target=int(str(row.get("is_target") or "1").strip() or "1"),
                )
            )
    return rows


def read_alias_rows(path: Path, known_slugs: set[str]) -> list[tuple[str, str, str]]:
    if not path.exists():
        return []
    out: list[tuple[str, str, str]] = []
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames != list(ALIAS_COLUMNS):
            raise AliasError(f"{path} must have header: {', '.join(ALIAS_COLUMNS)}")
        for line_no, row in enumerate(reader, start=2):
            alias = common.off_slug(row.get("alias_slug") or "")
            canonical = common.off_slug(row.get("canonical_slug") or "")
            note = (row.get("note") or "").strip()
            if not alias and not canonical:
                continue
            if not alias or not canonical:
                raise AliasError(f"{path}:{line_no}: alias_slug and canonical_slug are required")
            if canonical not in known_slugs:
                raise AliasError(f"{path}:{line_no}: unknown canonical_slug {canonical!r}")
            if alias in KNOWN_NON_TARGET_TAGS:
                raise AliasError(f"{path}:{line_no}: alias_slug {alias!r} is a known non-target tag")
            out.append((alias, canonical, note))
    return out


def _add_alias(
    rows_by_slug: dict[str, BrandRow],
    alias: str,
    canonical: str,
    *,
    source: str,
) -> bool:
    if alias in KNOWN_NON_TARGET_TAGS:
        raise AliasError(f"refusing alias {alias!r} from {source}: known non-target tag")
    if alias in rows_by_slug:
        return False
    canonical_row = rows_by_slug.get(canonical)
    if canonical_row is None:
        raise AliasError(f"refusing alias {alias!r}: canonical slug {canonical!r} is missing")
    rows_by_slug[alias] = BrandRow(
        brand_slug=alias,
        brand_name=canonical_row.brand_name,
        parent=canonical_row.parent,
        is_target=canonical_row.is_target,
    )
    return True


def write_brand_rows(path: Path, rows_by_slug: dict[str, BrandRow]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["brand_slug", "brand_name", "parent", "is_target"])
        for slug in sorted(rows_by_slug):
            row = rows_by_slug[slug]
            writer.writerow([row.brand_slug, row.brand_name, row.parent, row.is_target])


def reconcile(
    rows: list[BrandRow],
    facet_tags: dict[str, FacetTag],
    alias_rows: list[tuple[str, str, str]],
    *,
    fuzzy_limit: int = 5,
) -> tuple[dict[str, BrandRow], list[str]]:
    rows_by_slug = {row.brand_slug: row for row in rows}
    original_slugs = set(rows_by_slug)
    report: list[str] = []

    alias_added = 0
    for alias, canonical, note in alias_rows:
        if _add_alias(rows_by_slug, alias, canonical, source=f"aliases.csv ({note})"):
            alias_added += 1

    exact_added: list[tuple[str, str, int, str]] = []
    collisions: list[tuple[str, str]] = []
    for canonical in sorted(original_slugs):
        for candidate in sorted(generate_alias_candidates(canonical)):
            if candidate in KNOWN_NON_TARGET_TAGS:
                collisions.append((canonical, candidate))
                continue
            tag = facet_tags.get(candidate)
            if tag and candidate not in rows_by_slug:
                if _add_alias(rows_by_slug, candidate, canonical, source="generated exact facet hit"):
                    exact_added.append((candidate, canonical, tag.products, tag.dataset))

    if collisions:
        joined = ", ".join(f"{src}->{cand}" for src, cand in collisions)
        raise AliasError(f"generated aliases collided with known non-target tags: {joined}")

    facet_vocab = sorted(facet_tags)
    report.append("Brand Alias Reconciliation")
    report.append("==========================")
    report.append(f"input brand slugs:          {len(rows)}")
    report.append(f"reviewed aliases added:     {alias_added}")
    report.append(f"exact facet aliases added:  {len(exact_added)}")
    report.append(f"output brand slugs:         {len(rows_by_slug)}")
    report.append("")

    if exact_added:
        report.append("Exact facet aliases added")
        report.append("-------------------------")
        for alias, canonical, products, dataset in exact_added[:200]:
            report.append(f"{alias} -> {canonical} ({products} products, {dataset})")
        if len(exact_added) > 200:
            report.append(f"... {len(exact_added) - 200} more")
        report.append("")

    report.append("Fuzzy review suggestions")
    report.append("------------------------")
    if facet_vocab:
        for row in rows:
            if row.brand_slug in facet_tags:
                continue
            close = difflib.get_close_matches(row.brand_slug, facet_vocab, n=fuzzy_limit, cutoff=0.88)
            if close:
                report.append(f"{row.brand_slug}: {', '.join(close)}")
    else:
        report.append("No facet vocabulary was available; fuzzy review skipped.")
    return rows_by_slug, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Merge reviewed/exact OFF brand-tag aliases into brands.csv.")
    parser.add_argument("--brands", type=Path, default=common.BRANDS_CSV,
                        help="brands CSV to update in place")
    parser.add_argument("--aliases", type=Path, default=common.ALIASES_CSV,
                        help="reviewed aliases CSV")
    parser.add_argument("--facet-cache", type=Path, default=common.BRAND_FACET_CACHE,
                        help="facet cache path")
    parser.add_argument("--refresh-facets", action="store_true",
                        help="ignore facet cache and fetch OFF-family facets")
    args = parser.parse_args(argv)

    rows = read_brand_rows(args.brands)
    if not rows:
        print(f"ERROR: no brand rows found in {args.brands}", file=sys.stderr)
        return 2

    facet_tags, notes = fetch_or_load_facets(args.facet_cache, refresh=args.refresh_facets)
    alias_rows = read_alias_rows(args.aliases, {r.brand_slug for r in rows})
    rows_by_slug, report = reconcile(rows, facet_tags, alias_rows)

    write_brand_rows(args.brands, rows_by_slug)
    common.ensure_out()
    common.ALIAS_REVIEW_TXT.write_text("\n".join(report) + "\n", encoding="utf-8")

    print("reconcile_brands.py")
    for note in notes:
        print(f"  - {note}")
    print(f"  reviewed aliases: {len(alias_rows)} rows from {args.aliases}")
    print(f"  brands: {len(rows)} -> {len(rows_by_slug)}")
    print(f"  review report: {common.ALIAS_REVIEW_TXT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
