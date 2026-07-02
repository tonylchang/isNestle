"""Shared exception-rule parsing and application for the data pipeline."""
from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from pathlib import Path

import common


EXCEPTION_COLUMNS = (
    "brand_slug",
    "scope_type",
    "scope_value",
    "actual_maker",
    "action",
    "note",
    "source_url",
)
VALID_SCOPE_TYPES = {"co_brand", "country", "prefix"}
VALID_ACTIONS = {"exclude", "reattribute"}


class RuleError(ValueError):
    """Raised when an exception rule is malformed or unsafe."""


@dataclass(frozen=True)
class ExceptionRule:
    brand_slug: str
    scope_type: str
    scope_value: str
    actual_maker: str
    action: str
    note: str
    source_url: str


@dataclass(frozen=True)
class RuleApplication:
    action: str
    actual_maker: str
    note: str
    rule: ExceptionRule


def _normalize_scope(scope_type: str, value: str) -> str:
    value = (value or "").strip()
    if scope_type == "co_brand":
        return common.off_slug(value)
    if scope_type == "country":
        return value.lower()
    if scope_type == "prefix":
        digits = re.sub(r"\D", "", value)
        if not digits:
            raise RuleError("prefix scope_value must contain digits")
        return digits
    return value


def parse_exception_row(row: dict, *, line_no: int, known_slugs: set[str] | None = None) -> ExceptionRule | None:
    if not any((row.get(col) or "").strip() for col in EXCEPTION_COLUMNS):
        return None

    brand_slug = common.off_slug(row.get("brand_slug") or "")
    scope_type = (row.get("scope_type") or "").strip()
    action = (row.get("action") or "").strip()
    source_url = (row.get("source_url") or "").strip()
    actual_maker = (row.get("actual_maker") or "").strip()
    note = (row.get("note") or "").strip()

    if not brand_slug:
        raise RuleError(f"exceptions.csv:{line_no}: brand_slug is required")
    if known_slugs is not None and brand_slug not in known_slugs:
        raise RuleError(f"exceptions.csv:{line_no}: unknown brand_slug {brand_slug!r}")
    if scope_type not in VALID_SCOPE_TYPES:
        raise RuleError(f"exceptions.csv:{line_no}: scope_type must be one of {sorted(VALID_SCOPE_TYPES)}")
    if action not in VALID_ACTIONS:
        raise RuleError(f"exceptions.csv:{line_no}: action must be one of {sorted(VALID_ACTIONS)}")
    if action == "reattribute" and not actual_maker:
        raise RuleError(f"exceptions.csv:{line_no}: actual_maker is required for reattribute")
    if not note:
        raise RuleError(f"exceptions.csv:{line_no}: note is required")
    if not source_url or not re.match(r"^https?://", source_url):
        raise RuleError(f"exceptions.csv:{line_no}: source_url must be an http(s) URL")

    scope_value = _normalize_scope(scope_type, row.get("scope_value") or "")
    if not scope_value:
        raise RuleError(f"exceptions.csv:{line_no}: scope_value is required")

    return ExceptionRule(
        brand_slug=brand_slug,
        scope_type=scope_type,
        scope_value=scope_value,
        actual_maker=actual_maker,
        action=action,
        note=note,
        source_url=source_url,
    )


def read_exception_rules(path: Path = common.EXCEPTIONS_CSV, known_slugs: set[str] | None = None) -> list[ExceptionRule]:
    if not path.exists():
        return []
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames != list(EXCEPTION_COLUMNS):
            raise RuleError(f"{path} must have header: {', '.join(EXCEPTION_COLUMNS)}")
        out: list[ExceptionRule] = []
        for line_no, row in enumerate(reader, start=2):
            rule = parse_exception_row(row, line_no=line_no, known_slugs=known_slugs)
            if rule is not None:
                out.append(rule)
        return out


def rule_matches(
    rule: ExceptionRule,
    *,
    brand_slug: str,
    barcode: str,
    brands_tags: list[str],
    countries_tags: list[str],
) -> bool:
    if rule.brand_slug != brand_slug:
        return False
    if rule.scope_type == "co_brand":
        return rule.scope_value in set(brands_tags)
    if rule.scope_type == "country":
        # Country-scope rules are intentionally narrow: one country tag only.
        country_set = set(countries_tags)
        return len(country_set) == 1 and rule.scope_value in country_set
    if rule.scope_type == "prefix":
        gtin = common.normalize_gtin13(barcode)
        raw = re.sub(r"\D", "", barcode or "")
        variants = {rule.scope_value}
        if len(rule.scope_value) < 13:
            variants.add("0" + rule.scope_value)
        return bool(
            gtin
            and any(
                gtin.startswith(value) or raw.startswith(value)
                for value in variants
                if value
            )
        )
    return False


def apply_exception_rules(
    brand_slug: str,
    barcode: str,
    brands_tags: list[str],
    countries_tags: list[str],
    exception_rules: list[ExceptionRule],
) -> RuleApplication | None:
    for rule in exception_rules:
        if rule_matches(
            rule,
            brand_slug=brand_slug,
            barcode=barcode,
            brands_tags=brands_tags,
            countries_tags=countries_tags,
        ):
            return RuleApplication(
                action=rule.action,
                actual_maker=rule.actual_maker,
                note=rule.note,
                rule=rule,
            )
    return None
