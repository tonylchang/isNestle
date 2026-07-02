"""Shared contract for the isNestle data-pipeline spike (Milestone 0).

Both pipeline halves import from here so they cannot drift on the two things
that must agree: the brand *slug* format and how we talk to the network.

Stdlib only (Python 3.12+ in CI) — no pip installs, to keep the parallel agents from
racing on a shared environment.
"""
from __future__ import annotations

import json
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# --- Paths -------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent          # data-pipeline/
OUT = ROOT / "out"                              # generated artifacts (gitignored)
SCHEMA_SQL = ROOT / "schema.sql"
BRANDS_CSV = OUT / "brands.csv"                  # produced by build_brands.py (Agent A)
BARCODES_CSV = OUT / "barcodes.csv"             # produced by build_barcodes.py (Agent B)
PREFIX_CORPUS_CSV = OUT / "prefix_corpus.csv"   # produced by dump-mode barcode collection
PREFIXES_CSV = OUT / "prefixes.csv"             # produced by build_prefixes.py
SQLITE_DB = OUT / "isnestle.sqlite"             # produced by build_db.py (Agent B)
ALIASES_CSV = ROOT / "aliases.csv"              # reviewed brand-tag aliases
EXCEPTIONS_CSV = ROOT / "exceptions.csv"        # reviewed false-positive rules
ALIAS_REVIEW_TXT = OUT / "alias_review.txt"
BRAND_FACET_CACHE = OUT / "brand_facets.json"

# --- Constants ---------------------------------------------------------------
PARENT_DEFAULT = "Nestlé"
WIKIDATA_SPARQL = "https://query.wikidata.org/sparql"
WIKIDATA_NESTLE_QID = "Q160746"
OFF_SEARCH_URL = "https://search.openfoodfacts.org/search"  # Search-a-licious (fast)
# OFF-family sibling DBs (all ODbL). They don't run Search-a-licious, so the
# barcode pipeline queries their classic Product Opener REST API (/api/v2/search).
OPFF_SEARCH_URL = "https://world.openpetfoodfacts.org/api/v2/search"   # pet care (Purina)
OBF_SEARCH_URL = "https://world.openbeautyfacts.org/api/v2/search"     # cosmetics
OPF_SEARCH_URL = "https://world.openproductsfacts.org/api/v2/search"   # household / non-food
USER_AGENT = "isNestle-data-spike/0.1 (https://github.com/tonylchang/isNestle; M0 data pipeline)"

CSV_FIELD_SIZE_LIMIT = 1024 * 1024 * 128


# --- Brand slug: THE integration contract ------------------------------------
def off_slug(name: str) -> str:
    """Normalize a brand name to an Open Food Facts–style tag slug.

    Lowercase, strip accents, non-alphanumerics -> single hyphen, trimmed.
    Examples: 'Nestlé' -> 'nestle', 'Kit Kat' -> 'kit-kat',
              'S.Pellegrino' -> 's-pellegrino', 'Coffee-Mate' -> 'coffee-mate'.

    NOTE: OFF's own tagger is not identical (e.g. it may emit 'kitkat'), so the
    barcode side must ALSO reconcile against the actual brands_tags it sees and
    report mismatches. Measuring that gap is a primary goal of this spike.
    """
    if not name:
        return ""
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s


def parse_tag_list(value) -> list[str]:
    """Return normalized OFF-style tags from a CSV/API field.

    OFF API responses expose tags as lists, while dumps expose comma-separated
    strings. The dump values are already slug-like; ``off_slug`` keeps synthetic
    unit tests and occasional plain-text values aligned with the rest of the
    pipeline.
    """
    if value is None:
        return []
    if isinstance(value, (list, tuple, set)):
        raw = value
    else:
        raw = str(value).split(",")
    out: list[str] = []
    seen: set[str] = set()
    for item in raw:
        tag = str(item).strip().lower()
        if not tag:
            continue
        # Preserve OFF language prefixes in country tags (e.g. en:united-states)
        # but normalize ordinary brand tags.
        if ":" in tag:
            lang, value = tag.split(":", 1)
            slug_value = off_slug(value)
            slug = f"{lang}:{slug_value}" if re.fullmatch(r"[a-z]{2}", lang) and slug_value else ""
        else:
            slug = off_slug(tag)
        if slug and slug not in seen:
            seen.add(slug)
            out.append(slug)
    return out


def normalize_gtin13(barcode: str) -> str | None:
    """Normalize a UPC/EAN-ish barcode to GTIN-13, or return None if invalid."""
    digits = re.sub(r"\D", "", barcode or "")
    if not digits or len(digits) > 13:
        return None
    return digits.zfill(13)


# --- Resilient HTTP (OFF/Wikidata are slow & occasionally flaky) -------------
def http_get_json(url: str, params: dict | None = None, *, timeout: int = 30,
                  retries: int = 4, backoff: float = 2.0):
    """GET JSON with a proper User-Agent, retries, and linear backoff."""
    if params:
        url = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, urllib.error.HTTPError,
                TimeoutError, json.JSONDecodeError, ConnectionError) as exc:
            last = exc
            time.sleep(backoff * (attempt + 1))
    raise RuntimeError(f"GET failed after {retries} attempts: {url} :: {last!r}")


def ensure_out() -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    return OUT
