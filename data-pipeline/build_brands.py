#!/usr/bin/env python3
"""build_brands.py — Milestone 0 data spike, Agent A.

Builds the brand -> parent-company table for isNestle.

Output: out/brands.csv  with header `brand_slug,brand_name,parent,is_target`.
One row per Nestlé-owned brand; parent="Nestlé", is_target=1.

Sources (all best-effort; a partial failure of one source does NOT abort the run):
  1. Wikidata SPARQL  — transitive ownership closure of Nestlé (Q160746).
  2. Wikipedia        — "List of Nestlé brands" wikitext (MediaWiki parse API).
  3. Curated aliases  — hand-picked slug variants for major brands, because
                        OFF's brands_tags are inconsistent.

Stdlib only (Python 3.12+). Re-runnable: overwrites out/brands.csv each run.

Run:  python3 build_brands.py
"""
from __future__ import annotations

import csv
import re
import sys
import traceback

from common import (
    BRANDS_CSV,
    PARENT_DEFAULT,
    WIKIDATA_NESTLE_QID,
    WIKIDATA_SPARQL,
    ensure_out,
    http_get_json,
    off_slug,
)

# Companies Nestlé only holds/held a *minority* stake in, or has divested — their
# products are NOT "made by Nestlé". We prune these whole sub-trees so cosmetics
# (L'Oréal/Galderma) and pharma/eye-care (Sanofi/Novartis/Alcon) don't become
# false positives. (QIDs resolved via wikidata wbsearchentities.)
WIKIDATA_EXCLUDE_QIDS = {
    "Q156077": "L'Oréal (cosmetics, ~20% Nestlé stake)",
    "Q581008": "Galderma (dermatology, divested JV)",
    "Q684825": "Alcon (eye care, sold to Novartis)",
    "Q507154": "Novartis (pharma, not Nestlé-owned)",
    "Q158205": "Sanofi (pharma, not Nestlé-owned)",
    "Q837851": "The Body Shop (cosmetics, not Nestlé)",
}

# Belt-and-suspenders denylist applied to *every* source by slug, in case the
# Wikidata in-query exclusion is bypassed (e.g. the fallback plain query runs).
# NOTE: this is only belt-and-suspenders. The real protection is that
# fetch_wikidata uses ONLY the subtree-excluding query (no unpruned fallback);
# a per-slug denylist can never be exhaustive for whole corporate empires.
DENY_SLUGS = {
    # L'Oréal (Nestlé holds only a minority stake — not "made by Nestlé")
    "loreal", "l-oreal", "loreal-paris", "l-oreal-paris", "l-oreal-professionnel",
    "l-oreal-usa", "l-oreal-baltic", "l-oreal-foundation",
    "garnier", "maybelline", "lancome", "urban-decay", "kiehl-s", "redken",
    "kerastase", "la-roche-posay", "vichy", "cerave", "nyx", "essie",
    "the-body-shop", "body-shop", "yves-saint-laurent", "ysl-beauty",
    "biotherm", "biolage", "cadum", "carita", "cacharel", "aesop",
    "helena-rubinstein", "maison-margiela", "mizani", "matrix", "decleor",
    "prada-beauty", "miu-miu", "valentino-beauty", "clarisonic", "skinceuticals",
    "stylenanda", "youth-to-the-people", "takami", "yuesai", "mugler", "azzaro",
    # Galderma / dermatology (divested JV)
    "galderma", "cetaphil",
    # Alcon / eye care (sold to Novartis)
    "alcon", "novartis",
    # Sanofi / pharma (not Nestlé-owned)
    "sanofi", "sanofi-aventis", "sanofi-pasteur", "genzyme", "bioverativ",
    "regeneron-pharmaceuticals", "opella",
}

# Wikidata's P176 ("manufacturer") edge drags in Nestlé's *patent portfolio* as
# if each invention were a brand (e.g. "method-for-cooking-food-in-a-..."). These
# are harmless (zero barcodes) but pollute the table, so drop anything that reads
# like a patent/process/composition rather than a consumer brand. High-precision:
# none of these tokens appear in real Nestlé brand names, and the >=6-word rule
# spares real multi-word lines like "purina-pro-plan-veterinary-diets" (5 words).
_NON_BRAND_WORDS = {
    "composition", "compositions", "method", "methods", "apparatus",
    "apparatuses", "device", "devices", "process", "comprising", "thereof",
    "dispenser", "dispensing", "formulation", "formulations", "packaging",
    "package", "vessel", "frothing", "foaming", "brewing", "microorganisms",
    "oligosaccharide", "oligosaccharides", "probiotic", "triacylglyceride",
    "melatonin", "immunotherapy", "enteral", "swallowing", "nociception",
    "myelination", "particles", "infants",
}


def is_non_brand_noise(slug: str) -> bool:
    """True if a slug looks like a patent/process title, not a consumer brand."""
    words = slug.split("-")
    if len(words) >= 6:                     # long descriptive phrase => not a brand
        return True
    return any(w in _NON_BRAND_WORDS for w in words)


# Ownership/containment edges used to walk Nestlé's portfolio.
#   P127 owner, P176 manufacturer, P749 parent org, P355 subsidiary (inverse),
#   P1830 owner-of (inverse).  The path below means: "?item is reachable from
#   Nestlé by following ownership upward (or being a subsidiary/owned-of)."
_PATH = "(wdt:P127|wdt:P176|wdt:P749|^wdt:P355|^wdt:P1830)"


def _sparql_rich() -> str:
    excludes = "\n".join(
        f"  FILTER NOT EXISTS {{ ?item {_PATH}* wd:{qid} }}"
        for qid in WIKIDATA_EXCLUDE_QIDS
    )
    return (
        "SELECT DISTINCT ?item ?itemLabel WHERE {\n"
        f"  ?item {_PATH}+ wd:{WIKIDATA_NESTLE_QID} .\n"
        f"{excludes}\n"
        '  ?item rdfs:label ?itemLabel . FILTER(LANG(?itemLabel) = "en")\n'
        "}"
    )


def fetch_wikidata() -> tuple[list[str], list[str]]:
    """Return (brand_names, notes). Never raises — resilient by contract.

    ONLY the rich, subtree-excluding query is used. There is deliberately no
    plain-query fallback: the plain transitive closure pulls in Nestlé's
    minority-stake and divested empires (L'Oréal, Sanofi, Alcon, …) as if they
    were Nestlé brands, and the slug denylist alone does not catch them
    (l-oreal-paris, biotherm, aesop, …). If the exclusion query is unavailable
    (e.g. WDQS is rate-limiting during an outage), we drop Wikidata for this run
    and fall back to the Wikipedia + curated sources only — a smaller but clean
    brand list beats a larger contaminated one. A shrunk run is then caught by
    check_counts.py and the L'Oréal negative anchors in test_spike.py.
    """
    notes: list[str] = []
    try:
        # WDQS may be under an active-outage rule that rate-limits to ~1 req/min.
        # Default backoff retries all land inside the same blocked minute, so
        # wait out the window (~65s) between attempts, and try a few times.
        data = http_get_json(
            WIKIDATA_SPARQL,
            {"query": _sparql_rich(), "format": "json"},
            timeout=90,
            retries=5,
            backoff=65,
        )
    except Exception as exc:  # noqa: BLE001 — best-effort source
        notes.append(f"wikidata: exclusion query UNAVAILABLE — {exc!r}")
        notes.append("wikidata: dropped for this run (no unpruned fallback — "
                     "would import L'Oréal/Sanofi/Alcon as false Nestlé brands)")
        return [], notes

    names, excluded = _labels_from_sparql(data)
    notes.append(f"wikidata: {len(names)} labels (excluded {excluded} minority/divested roots)")
    return names, notes


def _labels_from_sparql(data: dict) -> tuple[list[str], int]:
    """Extract usable brand labels from a WDQS JSON response (pure, testable).

    Returns (labels, excluded_count). Skips empty labels, items whose label is
    just their own QID (un-labelled), and the minority/divested exclusion roots.
    """
    names: list[str] = []
    excluded = 0
    for b in data.get("results", {}).get("bindings", []):
        label = b.get("itemLabel", {}).get("value", "").strip()
        uri = b.get("item", {}).get("value", "")
        m = re.search(r"(Q\d+)", uri)
        qid = m.group(1) if m else ""
        if not label:
            continue
        # Skip un-labelled items that come back as their own QID.
        if re.fullmatch(r"Q\d+", label):
            continue
        if qid in WIKIDATA_EXCLUDE_QIDS:
            excluded += 1
            continue
        names.append(label)
    return names, excluded


# --- Wikipedia "List of Nestlé brands" ---------------------------------------
WIKIPEDIA_API = "https://en.wikipedia.org/w/api.php"
WIKIPEDIA_PAGE = "List of Nestlé brands"


def _clean_wikitext(s: str) -> str:
    s = re.sub(r"<ref[^>]*?/>", "", s)                       # self-closed refs
    s = re.sub(r"<ref[^>]*?>.*?</ref>", "", s, flags=re.S)   # inline refs
    s = re.split(r"<ref", s, maxsplit=1)[0]                  # dangling/multiline ref open
    s = re.sub(r"\{\{[^{}]*\}\}", "", s)                     # templates
    return s


def _extract_brand(line: str) -> str | None:
    s = line.lstrip("*").strip()
    if not s or s[0] in "{|":            # citation / table noise
        return None
    s = _clean_wikitext(s).strip()
    if not s:
        return None
    m = re.match(r"\[\[\s*(?:[^|\]]*\|)?\s*([^\]]+?)\s*\]\]", s)
    if m:
        name = m.group(1)
    else:
        # plain text up to first delimiter: ( < { tab , or " – " dash separator
        name = re.split(r"[(<{\t]|\s[–—-]\s|,", s, maxsplit=1)[0]
    name = re.sub(r"\[\[|\]\]", "", name)
    name = name.strip().strip("'\"").strip()
    name = re.sub(r"\s+", " ", name)
    name = re.sub(r"\s*\([^)]*\)\s*$", "", name).strip()     # trailing disambig parens
    if len(name) < 2:
        return None
    low = name.lower()
    if low.startswith(("cite ", "http", "category:", "file:", "image:", "{{")):
        return None
    return name


def _heading(line: str) -> str | None:
    m = re.match(r"^=+\s*([^=].*?)\s*=+\s*$", line)
    return m.group(1).strip() if m else None


def _brands_from_wikitext(wt: str) -> list[str]:
    """Extract current-brand names from the page's raw wikitext (pure, testable).

    Collects only the "current brands" region: from the first content heading
    ("Beverages") up to "As shareholder" (minority stakes) / "Former brands"
    (divested) — those are NOT currently made by Nestlé.
    """
    lines = wt.splitlines()

    def find(name: str, default: int) -> int:
        for i, ln in enumerate(lines):
            if _heading(ln) == name:
                return i
        return default

    start = find("Beverages", 0)
    stop = min(
        find("As shareholder", len(lines)),
        find("Former brands", len(lines)),
    )
    region = lines[start:stop] if stop > start else lines[start:]

    names: list[str] = []
    in_ref = False
    for ln in region:
        if in_ref:
            if "</ref>" in ln:
                in_ref = False
            continue
        if ln.startswith("*"):
            n = _extract_brand(ln)
            if n:
                names.append(n)
        opens = len(re.findall(r"<ref(?:\s[^>]*)?>", ln)) - len(re.findall(r"<ref[^>]*?/>", ln))
        if opens > ln.count("</ref>"):
            in_ref = True
    return names


def fetch_wikipedia() -> tuple[list[str], list[str]]:
    """Return (brand_names, notes). Never raises."""
    notes: list[str] = []
    try:
        data = http_get_json(
            WIKIPEDIA_API,
            {"action": "parse", "page": WIKIPEDIA_PAGE,
             "prop": "wikitext", "format": "json", "redirects": "1"},
            timeout=45,
        )
    except Exception as exc:  # noqa: BLE001
        notes.append(f"wikipedia: UNAVAILABLE — {exc!r}")
        return [], notes

    if "parse" not in data:
        notes.append(f"wikipedia: no 'parse' in response ({list(data)}) — skipping")
        return [], notes

    names = _brands_from_wikitext(data["parse"]["wikitext"]["*"])
    notes.append(f"wikipedia: {len(names)} brand names from current-brand sections")
    return names, notes


# --- Curated seed brands ------------------------------------------------------
# Canonical display names that should be present even if Wikidata/Wikipedia are
# unavailable or temporarily thin. Slug variants live in aliases.csv and are
# merged by reconcile_brands.py so curation is data-driven.
CURATED: list[tuple[str, list[str]]] = [
    ("Nestlé", ["Nestlé"]),
    ("KitKat", ["KitKat"]),
    ("Nescafé", ["Nescafé"]),
    ("Coffee-Mate", ["Coffee-Mate"]),
    ("San Pellegrino", ["San Pellegrino"]),
    ("Perrier", ["Perrier"]),
    ("Vittel", ["Vittel"]),
    ("Acqua Panna", ["Acqua Panna"]),
    ("Purina", ["Purina"]),
    ("Häagen-Dazs", ["Häagen-Dazs"]),
    ("Smarties", ["Smarties"]),
    ("Aero", ["Aero"]),
    ("Milkybar", ["Milkybar"]),
    ("Crunch", ["Crunch"]),
    ("Toll House", ["Toll House"]),
    ("Stouffer's", ["Stouffer's"]),
    ("Lean Cuisine", ["Lean Cuisine"]),
    ("Gerber", ["Gerber"]),
    ("Garden Gourmet", ["Garden Gourmet"]),
    ("Sweet Earth", ["Sweet Earth"]),
    ("Blue Bottle", ["Blue Bottle"]),
    ("Nespresso", ["Nespresso"]),
    ("Cheerios", ["Cheerios"]),          # via Cereal Partners Worldwide (Nestlé/GM JV)
    ("Shredded Wheat", ["Shredded Wheat"]),
]


def fetch_curated() -> tuple[list[tuple[str, str]], list[str]]:
    """Return (list of (display_name, variant_string), notes). Never raises."""
    out: list[tuple[str, str]] = []
    for canonical, variants in CURATED:
        for v in variants:
            out.append((canonical, v))
    return out, [f"curated: {len(CURATED)} brands, {len(out)} variant spellings"]


# --- Merge & write ------------------------------------------------------------
def main() -> int:
    ensure_out()
    notes: list[str] = []

    wd_names, n = fetch_wikidata(); notes += n
    wp_names, n = fetch_wikipedia(); notes += n
    cur_pairs, n = fetch_curated(); notes += n

    # slug -> (brand_name, source). First contributor wins the slug (PK), so we
    # process in priority order and tally each source's *new* contributions.
    table: dict[str, tuple[str, str]] = {}
    src_new = {"wikidata": 0, "wikipedia": 0, "curated": 0}
    src_raw = {"wikidata": len(wd_names), "wikipedia": len(wp_names), "curated": len(cur_pairs)}
    dropped_deny = 0
    dropped_empty = 0
    dropped_noise = 0

    def add(name: str, source: str, slug: str | None = None) -> None:
        nonlocal dropped_deny, dropped_empty, dropped_noise
        slug = off_slug(name) if slug is None else slug
        if not slug:
            dropped_empty += 1
            return
        if slug in DENY_SLUGS:
            dropped_deny += 1
            return
        if is_non_brand_noise(slug):
            dropped_noise += 1
            return
        if slug in table:
            return
        table[slug] = (name.strip(), source)
        src_new[source] += 1

    for nm in wd_names:
        add(nm, "wikidata")
    for nm in wp_names:
        add(nm, "wikipedia")
    # Curated: slug comes from each *variant spelling* (so 'Coffee Mate' ->
    # 'coffee-mate' AND 'Coffeemate' -> 'coffeemate'), but we display the
    # canonical name for every variant row.
    for canonical, variant in cur_pairs:
        add(canonical, "curated", slug=off_slug(variant))

    # Sort for stable, reviewable output.
    rows = sorted(table.items())

    with open(BRANDS_CSV, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["brand_slug", "brand_name", "parent", "is_target"])
        for slug, (name, _src) in rows:
            w.writerow([slug, name, PARENT_DEFAULT, 1])

    # ---- Summary -------------------------------------------------------------
    print("=" * 64)
    print("build_brands.py — brand -> parent table")
    print("=" * 64)
    print("Source notes:")
    for note in notes:
        print(f"  - {note}")
    print()
    print(f"Per-source raw labels:   wikidata={src_raw['wikidata']:5d}  "
          f"wikipedia={src_raw['wikipedia']:4d}  curated={src_raw['curated']:3d}")
    print(f"Per-source NEW slugs:    wikidata={src_new['wikidata']:5d}  "
          f"wikipedia={src_new['wikipedia']:4d}  curated={src_new['curated']:3d}")
    print(f"Dropped (denylist={dropped_deny}, noise={dropped_noise}, empty-slug={dropped_empty})")
    print(f"TOTAL unique brands: {len(rows)}")
    print(f"Wrote: {BRANDS_CSV}")
    print()
    print("Sample rows:")
    sample_idx = [int(i * (len(rows) - 1) / 11) for i in range(12)] if len(rows) > 12 else range(len(rows))
    seen = set()
    for i in sample_idx:
        if i in seen:
            continue
        seen.add(i)
        slug, (name, src) = rows[i]
        print(f"  {slug:28s} {name[:32]:32s} {PARENT_DEFAULT}  is_target=1  [{src}]")

    if len(rows) < 50:
        print("\nWARNING: brand count is low — a source likely failed (see notes).")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # last-resort: never crash silently
        traceback.print_exc()
        sys.exit(2)
