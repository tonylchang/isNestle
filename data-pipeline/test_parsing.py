#!/usr/bin/env python3
"""test_parsing.py — offline unit tests for the pipeline's parsing functions.

The scraping/normalization regexes are the part of the pipeline that regresses
silently (a Wikipedia format drift shrinks output instead of erroring), so they
get real tests: off_slug, the non-brand noise filter, the wikitext extractors,
CSV reading, and the shrink guard. No network. Run:

    python3 test_parsing.py
"""
from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import build_barcodes
import build_brands
import build_db
import build_prefixes
import check_counts
import common
import reconcile_brands
import rules


class OffSlugTests(unittest.TestCase):
    def test_strips_accents(self):
        self.assertEqual(common.off_slug("Nestlé"), "nestle")
        self.assertEqual(common.off_slug("Häagen-Dazs"), "haagen-dazs")

    def test_spaces_and_punctuation_become_single_hyphens(self):
        self.assertEqual(common.off_slug("Kit Kat"), "kit-kat")
        self.assertEqual(common.off_slug("S.Pellegrino"), "s-pellegrino")
        self.assertEqual(common.off_slug("  Coffee -- Mate!! "), "coffee-mate")
        self.assertEqual(common.off_slug("Purina ONE"), "purina-one")

    def test_empty_and_non_latin_input(self):
        self.assertEqual(common.off_slug(""), "")
        # NFKD does not romanize CJK; everything is stripped. Callers must treat
        # an empty slug as "drop this name", which build_brands.main does.
        self.assertEqual(common.off_slug("雀巢"), "")


class TagListTests(unittest.TestCase):
    def test_country_tags_are_lowercased_and_slugged(self):
        self.assertEqual(
            common.parse_tag_list("EN:United States, en:canada"),
            ["en:united-states", "en:canada"],
        )

    def test_brand_tags_are_normalized_and_deduped(self):
        self.assertEqual(
            common.parse_tag_list(["Nestlé", "nestle", "Kit Kat"]),
            ["nestle", "kit-kat"],
        )


class NonBrandNoiseTests(unittest.TestCase):
    def test_patent_style_phrases_are_noise(self):
        self.assertTrue(build_brands.is_non_brand_noise(
            "method-for-cooking-food-in-a-vessel"))          # >= 6 words
        self.assertTrue(build_brands.is_non_brand_noise(
            "compositions-comprising-human-milk-oligosaccharides"))  # token hit
        self.assertTrue(build_brands.is_non_brand_noise("milk-packaging"))

    def test_real_brands_are_spared(self):
        self.assertFalse(build_brands.is_non_brand_noise("kit-kat"))
        self.assertFalse(build_brands.is_non_brand_noise("aero"))
        # 5 words, no noise tokens — the documented hard case from FINDINGS.md.
        self.assertFalse(build_brands.is_non_brand_noise(
            "purina-pro-plan-veterinary-diets"))

    def test_word_count_boundary(self):
        self.assertFalse(build_brands.is_non_brand_noise("one-two-three-four-five"))
        self.assertTrue(build_brands.is_non_brand_noise("one-two-three-four-five-six"))


class WikitextHelperTests(unittest.TestCase):
    def test_heading(self):
        self.assertEqual(build_brands._heading("== Beverages =="), "Beverages")
        self.assertEqual(build_brands._heading("===Sub heading==="), "Sub heading")
        self.assertEqual(build_brands._heading("==As shareholder=="), "As shareholder")
        self.assertIsNone(build_brands._heading("* KitKat"))
        self.assertIsNone(build_brands._heading("plain text"))

    def test_clean_wikitext(self):
        self.assertEqual(build_brands._clean_wikitext("Aero<ref name=x/> bar"), "Aero bar")
        self.assertEqual(build_brands._clean_wikitext("Aero<ref>cite</ref> bar"), "Aero bar")
        self.assertEqual(build_brands._clean_wikitext("Aero<ref name=y>dangling"), "Aero")
        self.assertEqual(build_brands._clean_wikitext("Milo{{efn|note}} drink"), "Milo drink")

    def test_extract_brand_links(self):
        self.assertEqual(build_brands._extract_brand("* [[KitKat]]"), "KitKat")
        self.assertEqual(build_brands._extract_brand("* [[Kit Kat (brand)|KitKat]]"), "KitKat")
        self.assertEqual(
            build_brands._extract_brand("* [[Aero (chocolate)|Aero]]<ref>src</ref>"), "Aero")

    def test_extract_brand_plain_text(self):
        self.assertEqual(build_brands._extract_brand("* Nescafé – instant coffee"), "Nescafé")
        self.assertEqual(build_brands._extract_brand("* Milo (drink)"), "Milo")
        self.assertEqual(build_brands._extract_brand("* Smarties, chocolate"), "Smarties")

    def test_extract_brand_rejects_noise(self):
        self.assertIsNone(build_brands._extract_brand("* {{cite web|url=x}}"))
        self.assertIsNone(build_brands._extract_brand("* "))
        self.assertIsNone(build_brands._extract_brand("* X"))              # too short
        self.assertIsNone(build_brands._extract_brand("* [[Category:Nestlé]]"))
        self.assertIsNone(build_brands._extract_brand("{| class=wikitable"))


class BrandsFromWikitextTests(unittest.TestCase):
    WIKITEXT = "\n".join([
        "Intro prose that must be ignored.",
        "== Beverages ==",
        "* [[Nescafé]]",
        "* [[Kit Kat|KitKat]]<ref>brand ref</ref>",
        "* Milo (drink)",
        "* {{cite web|url=noise}}",
        "* Aero – aerated chocolate",
        '<ref name="long">',
        "* Not-a-brand (inside a multiline ref, must be skipped)",
        "</ref>",
        "* [[Perrier]]",
        "== As shareholder ==",
        "* [[L'Oréal]]",
        "== Former brands ==",
        "* [[Alpo]]",
    ])

    def test_extracts_current_brands_only(self):
        self.assertEqual(
            build_brands._brands_from_wikitext(self.WIKITEXT),
            ["Nescafé", "KitKat", "Milo", "Aero", "Perrier"],
        )

    def test_excluded_sections_do_not_leak(self):
        names = build_brands._brands_from_wikitext(self.WIKITEXT)
        self.assertNotIn("L'Oréal", names)   # minority stake
        self.assertNotIn("Alpo", names)      # divested

    def test_missing_headings_fall_back_to_whole_page(self):
        wt = "* [[Nescafé]]\n* [[Perrier]]"
        self.assertEqual(build_brands._brands_from_wikitext(wt), ["Nescafé", "Perrier"])

    def test_empty_page_yields_nothing(self):
        self.assertEqual(build_brands._brands_from_wikitext(""), [])


class LabelsFromSparqlTests(unittest.TestCase):
    @staticmethod
    def _binding(label: str, qid: str) -> dict:
        return {"itemLabel": {"value": label},
                "item": {"value": f"http://www.wikidata.org/entity/{qid}"}}

    def test_extracts_labels_and_applies_filters(self):
        data = {"results": {"bindings": [
            self._binding("KitKat", "Q1"),
            self._binding("  Nescafé  ", "Q2"),        # whitespace stripped
            self._binding("", "Q3"),                    # empty label skipped
            self._binding("Q99999", "Q99999"),          # un-labelled item skipped
            self._binding("L'Oréal", "Q156077"),        # excluded minority-stake root
        ]}}
        names, excluded = build_brands._labels_from_sparql(data)
        self.assertEqual(names, ["KitKat", "Nescafé"])
        self.assertEqual(excluded, 1)

    def test_tolerates_missing_keys(self):
        self.assertEqual(build_brands._labels_from_sparql({}), ([], 0))
        self.assertEqual(build_brands._labels_from_sparql(
            {"results": {"bindings": [{}]}}), ([], 0))


class FetchWikidataFallbackTests(unittest.TestCase):
    """The exclusion query is the only trusted source; a failure must drop
    Wikidata, never fall back to the unpruned plain graph (which would import
    L'Oréal/Sanofi/Alcon as false Nestlé brands — a live incident on 2026-07-02)."""

    def setUp(self):
        self._orig = build_brands.http_get_json

    def tearDown(self):
        build_brands.http_get_json = self._orig

    def test_only_the_rich_exclusion_query_is_issued(self):
        queries = []

        def fake_get(url, params=None, **kwargs):
            queries.append(params["query"])
            return {"results": {"bindings": [
                {"itemLabel": {"value": "KitKat"},
                 "item": {"value": "http://www.wikidata.org/entity/Q1"}},
            ]}}

        build_brands.http_get_json = fake_get
        names, _notes = build_brands.fetch_wikidata()
        self.assertEqual(names, ["KitKat"])
        self.assertEqual(len(queries), 1)
        self.assertIn("FILTER NOT EXISTS", queries[0],
                      "the single query must be the subtree-excluding one")

    def test_failure_drops_wikidata_without_plain_fallback(self):
        calls = []

        def failing_get(url, params=None, **kwargs):
            calls.append(params["query"])
            raise RuntimeError("WDQS 429 rate limited")

        build_brands.http_get_json = failing_get
        names, notes = build_brands.fetch_wikidata()
        self.assertEqual(names, [], "a failed exclusion query must yield no Wikidata brands")
        self.assertEqual(len(calls), 1, "must not retry with an unpruned plain query")
        self.assertTrue(any("dropped" in n for n in notes))

    def test_denylist_blocks_loreal_family_slugs(self):
        for slug in ("l-oreal-paris", "biotherm", "aesop", "sanofi-pasteur"):
            self.assertIn(slug, build_brands.DENY_SLUGS)


class ReadBrandSlugsTests(unittest.TestCase):
    def test_dedupes_preserving_order_and_skips_blanks(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "brands.csv"
            path.write_text(
                "brand_slug,brand_name,parent,is_target\n"
                "nestle,Nestlé,Nestlé,1\n"
                "kitkat,KitKat,Nestlé,1\n"
                "nestle,Nestlé dup,Nestlé,1\n"
                ",Blank slug,Nestlé,1\n",
                encoding="utf-8",
            )
            self.assertEqual(build_barcodes.read_brand_slugs(str(path)), ["nestle", "kitkat"])


class AliasReconciliationTests(unittest.TestCase):
    def test_candidate_generation_rules(self):
        candidates = reconcile_brands.generate_alias_candidates("kit-kat")
        self.assertIn("kitkat", candidates)
        self.assertIn("nestle-kit-kat", candidates)
        self.assertIn("stouffers", reconcile_brands.generate_alias_candidates("stouffer-s"))
        self.assertIn("stouffer-s", reconcile_brands.generate_alias_candidates("stouffers"))
        self.assertIn("foo", reconcile_brands.generate_alias_candidates("foo-inc"))

    def test_exact_facet_candidate_is_added(self):
        rows = [reconcile_brands.BrandRow("kit-kat", "KitKat", common.PARENT_DEFAULT, 1)]
        facets = {"kitkat": reconcile_brands.FacetTag("kitkat", 25, "off")}
        reconciled, report = reconcile_brands.reconcile(rows, facets, [])
        self.assertIn("kit-kat", reconciled)
        self.assertIn("kitkat", reconciled)
        self.assertEqual(reconciled["kitkat"].brand_name, "KitKat")
        self.assertTrue(any("exact facet aliases added" in line.lower() for line in report))

    def test_fuzzy_match_stays_in_report_only(self):
        rows = [reconcile_brands.BrandRow("nescafe", "Nescafé", common.PARENT_DEFAULT, 1)]
        facets = {"nescaffe": reconcile_brands.FacetTag("nescaffe", 5, "off")}
        reconciled, report = reconcile_brands.reconcile(rows, facets, [])
        self.assertNotIn("nescaffe", reconciled)
        self.assertTrue(any("nescafe:" in line for line in report))

    def test_known_non_target_generated_alias_fails(self):
        rows = [reconcile_brands.BrandRow("hersheys", "Hersheys", common.PARENT_DEFAULT, 1)]
        with self.assertRaises(reconcile_brands.AliasError):
            reconcile_brands.reconcile(rows, {}, [])

    def test_curated_alias_rejects_unknown_canonical_and_denylist(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "aliases.csv"
            path.write_text(
                "alias_slug,canonical_slug,note\n"
                "hershey-s,kit-kat,known non target\n",
                encoding="utf-8",
            )
            with self.assertRaises(reconcile_brands.AliasError):
                reconcile_brands.read_alias_rows(path, {"kit-kat"})

            path.write_text(
                "alias_slug,canonical_slug,note\n"
                "kitkat,missing,unknown canonical\n",
                encoding="utf-8",
            )
            with self.assertRaises(reconcile_brands.AliasError):
                reconcile_brands.read_alias_rows(path, {"kit-kat"})


class DumpRowFilteringTests(unittest.TestCase):
    def test_matching_row_kept_with_evidence_fields(self):
        row = {
            "code": "7613039869048",
            "brands_tags": "aero,nestle",
            "countries_tags": "en:united-states",
            "owner": "Nestlé",
        }
        candidate = build_barcodes.candidate_from_product_row(row, {"aero": 0}, "off-dump")
        self.assertIsNotNone(candidate)
        assert candidate is not None
        self.assertEqual(candidate.brand_slug, "aero")
        self.assertEqual(candidate.brands_tags, ["aero", "nestle"])
        self.assertEqual(candidate.countries_tags, ["en:united-states"])
        self.assertEqual(candidate.owner, "Nestlé")

    def test_non_matching_row_skipped_and_counter_evidence_detected(self):
        row = {"code": "7702535016688", "brands_tags": "coca-cola"}
        self.assertIsNone(build_barcodes.candidate_from_product_row(row, {"aero": 0}, "off-dump"))
        self.assertTrue(build_barcodes.row_is_counter_evidence(row, {"aero"}))

    def test_malformed_row_skipped_without_abort(self):
        self.assertIsNone(build_barcodes.candidate_from_product_row({}, {"aero": 0}, "off-dump"))
        self.assertFalse(build_barcodes.row_is_counter_evidence({}, {"aero"}))

    def test_exception_application_exclude_and_reattribute(self):
        candidate = build_barcodes.BarcodeCandidate(
            barcode="034000123456",
            brand_slug="kitkat",
            source="off-dump",
            brands_tags=["kitkat", "hershey-s"],
            countries_tags=["en:united-states"],
        )
        reattribute = rules.ExceptionRule(
            "kitkat", "co_brand", "hershey-s", "Hershey", "reattribute",
            "made under license", "https://example.test/source",
        )
        row, corpus = build_barcodes.apply_rules_to_candidate(candidate, [reattribute])
        self.assertIsNotNone(row)
        assert row is not None
        self.assertEqual(row[3], "Hershey")
        self.assertEqual(corpus, "other")

        exclude = rules.ExceptionRule(
            "kitkat", "co_brand", "hershey-s", "", "exclude",
            "not target", "https://example.test/source",
        )
        row, corpus = build_barcodes.apply_rules_to_candidate(candidate, [exclude])
        self.assertIsNone(row)
        self.assertEqual(corpus, "other")

    def test_dump_pipeline_falls_back_per_dataset_without_discarding_successes(self):
        original_dump = build_barcodes.run_dataset_dump
        original_api = build_barcodes.run_dataset_api
        original_corpus = common.PREFIX_CORPUS_CSV

        def fake_dump(dataset, slug_priority, collected, exception_rules, corpus_writer):
            if dataset["id"] == "bad":
                raise RuntimeError("synthetic dump failure")
            row = ("1111111111111", "aero", "good-dump", "", "", "exact", "1")
            collected[row[0]] = row
            corpus_writer.writerow([row[0], "good-dump", "target"])
            return {"id": dataset["id"], "mode": "dump", "new": 1}

        def fake_api(dataset, slugs, collected, exception_rules):
            row = ("2222222222222", "aero", "bad-api", "", "", "exact", "1")
            collected[row[0]] = row
            return {"id": dataset["id"], "mode": "api", "new": 1}

        with tempfile.TemporaryDirectory() as tmp:
            common.PREFIX_CORPUS_CSV = Path(tmp) / "prefix_corpus.csv"
            build_barcodes.run_dataset_dump = fake_dump
            build_barcodes.run_dataset_api = fake_api
            try:
                collected, stats = build_barcodes.run_dump_pipeline(
                    [{"id": "good"}, {"id": "bad"}],
                    ["aero"],
                    [],
                    api_fallback=True,
                )
            finally:
                build_barcodes.run_dataset_dump = original_dump
                build_barcodes.run_dataset_api = original_api
                common.PREFIX_CORPUS_CSV = original_corpus

        self.assertIn("1111111111111", collected)
        self.assertIn("2222222222222", collected)
        self.assertEqual([s["mode"] for s in stats], ["dump", "api"])
        self.assertEqual(stats[1]["fallback_from"], "dump")


class ExceptionRuleTests(unittest.TestCase):
    def test_co_brand_country_and_prefix_scopes(self):
        co_brand = rules.ExceptionRule(
            "kitkat", "co_brand", "hershey-s", "Hershey", "reattribute",
            "source note", "https://example.test/co",
        )
        country = rules.ExceptionRule(
            "smarties", "country", "en:united-states", "", "exclude",
            "source note", "https://example.test/country",
        )
        prefix = rules.ExceptionRule(
            "kitkat", "prefix", "034000", "Hershey", "reattribute",
            "source note", "https://example.test/prefix",
        )

        self.assertTrue(rules.rule_matches(
            co_brand,
            brand_slug="kitkat",
            barcode="034000123456",
            brands_tags=["kitkat", "hershey-s"],
            countries_tags=["en:united-states"],
        ))
        self.assertTrue(rules.rule_matches(
            country,
            brand_slug="smarties",
            barcode="1234567890123",
            brands_tags=["smarties"],
            countries_tags=["en:united-states"],
        ))
        self.assertFalse(rules.rule_matches(
            country,
            brand_slug="smarties",
            barcode="1234567890123",
            brands_tags=["smarties"],
            countries_tags=["en:united-states", "en:canada"],
        ))
        self.assertTrue(rules.rule_matches(
            prefix,
            brand_slug="kitkat",
            barcode="034000123456",
            brands_tags=["kitkat"],
            countries_tags=[],
        ))

    def test_rule_validation_requires_citation_and_known_slug(self):
        row = {
            "brand_slug": "kitkat",
            "scope_type": "co_brand",
            "scope_value": "hershey-s",
            "actual_maker": "Hershey",
            "action": "reattribute",
            "note": "source note",
            "source_url": "",
        }
        with self.assertRaises(rules.RuleError):
            rules.parse_exception_row(row, line_no=2, known_slugs={"kitkat"})

        row["source_url"] = "https://example.test/source"
        with self.assertRaises(rules.RuleError):
            rules.parse_exception_row(row, line_no=2, known_slugs={"aero"})


class CuratedExceptionCsvTests(unittest.TestCase):
    def test_committed_exception_seed_rules_load(self):
        exception_rules = rules.read_exception_rules(common.EXCEPTIONS_CSV)
        keyed = {
            (rule.brand_slug, rule.scope_type, rule.scope_value, rule.action)
            for rule in exception_rules
        }

        self.assertIn(("kitkat", "co_brand", "hershey-s", "reattribute"), keyed)
        self.assertIn(("kit-kat", "co_brand", "hershey-s", "reattribute"), keyed)
        self.assertIn(("crunch", "country", "en:united-states", "reattribute"), keyed)
        self.assertIn(("nestle-crunch", "country", "en:united-states", "reattribute"), keyed)
        self.assertIn(("smarties", "country", "en:united-states", "exclude"), keyed)
        for rule in exception_rules:
            self.assertTrue(rule.source_url.startswith("https://"), rule)
            if rule.action == "reattribute":
                self.assertTrue(rule.actual_maker, rule)

    def test_committed_exception_seed_rules_apply_to_synthetic_evidence(self):
        exception_rules = rules.read_exception_rules(common.EXCEPTIONS_CSV)

        kitkat = rules.apply_exception_rules(
            "kit-kat",
            "034000123456",
            ["kit-kat", "hershey-s"],
            [],
            exception_rules,
        )
        self.assertIsNotNone(kitkat)
        assert kitkat is not None
        self.assertEqual(kitkat.action, "reattribute")
        self.assertEqual(kitkat.actual_maker, "The Hershey Company")

        crunch = rules.apply_exception_rules(
            "nestle-crunch",
            "099900505890",
            ["nestle-crunch"],
            ["en:united-states"],
            exception_rules,
        )
        self.assertIsNotNone(crunch)
        assert crunch is not None
        self.assertEqual(crunch.actual_maker, "Ferrara Candy Company")

        smarties = rules.apply_exception_rules(
            "smarties",
            "011206112110",
            ["smarties"],
            ["en:united-states"],
            exception_rules,
        )
        self.assertIsNotNone(smarties)
        assert smarties is not None
        self.assertEqual(smarties.action, "exclude")

        ambiguous_smarties = rules.apply_exception_rules(
            "smarties",
            "011206112110",
            ["smarties"],
            ["en:united-states", "en:canada"],
            exception_rules,
        )
        self.assertIsNone(ambiguous_smarties)


class BuildDbExceptionTests(unittest.TestCase):
    def _write_fixture(self, tmp: str, exceptions_text: str) -> tuple[Path, Path]:
        tmp_path = Path(tmp)
        brands = tmp_path / "brands.csv"
        barcodes = tmp_path / "barcodes.csv"
        exceptions = tmp_path / "exceptions.csv"
        prefixes = tmp_path / "prefixes.csv"
        db = tmp_path / "isnestle.sqlite"

        brands.write_text(
            "brand_slug,brand_name,parent,is_target\n"
            "kitkat,KitKat,Nestle,1\n"
            "smarties,Smarties,Nestle,1\n",
            encoding="utf-8",
        )
        barcodes.write_text(
            "barcode,brand_slug,source,maker_override,override_note,match_basis,evidence_count\n"
            "034000123456,kitkat,synthetic,The Hershey Company,"
            "US Kit Kat is made under license by Hershey,exact,1\n",
            encoding="utf-8",
        )
        exceptions.write_text(exceptions_text, encoding="utf-8")
        prefixes.write_text("prefix,parent,is_target,evidence_count,source\n", encoding="utf-8")

        common.BARCODES_CSV = barcodes
        common.EXCEPTIONS_CSV = exceptions
        common.PREFIXES_CSV = prefixes
        common.SQLITE_DB = db
        return brands, db

    def _restore_common_paths(self, original) -> None:
        common.BARCODES_CSV, common.EXCEPTIONS_CSV, common.PREFIXES_CSV, common.SQLITE_DB = original

    def test_build_db_loads_cited_exceptions_and_override_rows(self):
        exceptions_text = (
            "brand_slug,scope_type,scope_value,actual_maker,action,note,source_url\n"
            "kitkat,co_brand,hershey-s,The Hershey Company,reattribute,"
            "US Kit Kat is made under license by Hershey,"
            "https://en.wikipedia.org/wiki/Kit_Kats_in_the_United_States\n"
            "smarties,country,en:united-states,Smarties Candy Company,exclude,"
            "US Smarties wafer candy is made by Smarties Candy Company,"
            "https://www.smarties.com/our-story/\n"
        )
        original = (common.BARCODES_CSV, common.EXCEPTIONS_CSV, common.PREFIXES_CSV, common.SQLITE_DB)
        with tempfile.TemporaryDirectory() as tmp:
            try:
                brands, db = self._write_fixture(tmp, exceptions_text)
                self.assertEqual(build_db.main(["--brands", str(brands)]), 0)
                with sqlite3.connect(db) as conn:
                    self.assertEqual(conn.execute("SELECT COUNT(*) FROM exceptions").fetchone()[0], 2)
                    row = conn.execute(
                        "SELECT b.parent, b.is_target, bc.maker_override, bc.override_note "
                        "FROM barcodes bc JOIN brands b ON bc.brand_slug = b.brand_slug "
                        "WHERE bc.barcode = ?",
                        ("034000123456",),
                    ).fetchone()
                self.assertEqual(row[0], "Nestle")
                self.assertEqual(row[1], 1)
                self.assertEqual(row[2], "The Hershey Company")
                self.assertIn("Hershey", row[3])
            finally:
                self._restore_common_paths(original)

    def test_build_db_fails_on_invalid_exception_rows(self):
        exceptions_text = (
            "brand_slug,scope_type,scope_value,actual_maker,action,note,source_url\n"
            "missing-brand,co_brand,hershey-s,The Hershey Company,reattribute,"
            "source note,https://example.test/source\n"
        )
        original = (common.BARCODES_CSV, common.EXCEPTIONS_CSV, common.PREFIXES_CSV, common.SQLITE_DB)
        with tempfile.TemporaryDirectory() as tmp:
            try:
                brands, _db = self._write_fixture(tmp, exceptions_text)
                self.assertEqual(build_db.main(["--brands", str(brands)]), 2)
            finally:
                self._restore_common_paths(original)


class PrefixInferenceTests(unittest.TestCase):
    def _barcodes(self, prefix: str, count: int) -> set[str]:
        return {f"{prefix}{i:0{13 - len(prefix)}d}" for i in range(count)}

    def test_dense_exclusive_prefix_accepted_with_longest_output(self):
        target = self._barcodes("1234567890", 12)
        counter = self._barcodes("987654", 20)
        candidates = build_prefixes.count_prefixes(target, counter)
        accepted = build_prefixes.accepted_prefixes(candidates, [], min_target=10)
        self.assertEqual([p.prefix for p in accepted], ["1234567890"])
        self.assertEqual(accepted[0].target_count, 12)

    def test_mixed_prefix_rejected(self):
        target = self._barcodes("123456", 12)
        counter = {"1234569999999"}
        candidates = build_prefixes.count_prefixes(target, counter)
        accepted = build_prefixes.accepted_prefixes(candidates, [], min_target=10)
        self.assertNotIn("123456", [p.prefix for p in accepted])

    def test_hard_excluded_ranges_rejected(self):
        target = self._barcodes("200000", 12)
        candidates = build_prefixes.count_prefixes(target, set())
        accepted = build_prefixes.accepted_prefixes(candidates, [], min_target=10)
        self.assertEqual(accepted, [])

    def test_prefix_exception_blocks_candidate(self):
        target = self._barcodes("0034000", 12)
        candidates = build_prefixes.count_prefixes(target, set())
        exception = rules.ExceptionRule(
            "kitkat", "prefix", "034000", "Hershey", "reattribute",
            "source note", "https://example.test/prefix",
        )
        accepted = build_prefixes.accepted_prefixes(candidates, [exception], min_target=10)
        self.assertEqual(accepted, [])


class CheckCountsTests(unittest.TestCase):
    def _write(self, tmp: str, name: str, brands: int, barcodes: int) -> Path:
        path = Path(tmp) / name
        path.write_text(json.dumps(
            {"version": "2026.01.01.0000", "brands": brands, "barcodes": barcodes}))
        return path

    def _run(self, prev, cur, extra=()):
        return check_counts.main(["--previous", str(prev), "--current", str(cur), *extra])

    def test_same_counts_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = self._write(tmp, "prev.json", 600, 33000)
            cur = self._write(tmp, "cur.json", 600, 33000)
            self.assertEqual(self._run(prev, cur), 0)

    def test_wobble_within_tolerance_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = self._write(tmp, "prev.json", 600, 33000)
            cur = self._write(tmp, "cur.json", 570, 31000)   # ~5-6% down
            self.assertEqual(self._run(prev, cur), 0)

    def test_material_shrink_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = self._write(tmp, "prev.json", 600, 33000)
            cur = self._write(tmp, "cur.json", 300, 33000)   # brands halved
            self.assertEqual(self._run(prev, cur), 1)

    def test_zero_previous_counts_never_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = self._write(tmp, "prev.json", 0, 0)
            cur = self._write(tmp, "cur.json", 600, 33000)
            self.assertEqual(self._run(prev, cur), 0)

    def test_max_shrink_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = self._write(tmp, "prev.json", 600, 33000)
            cur = self._write(tmp, "cur.json", 300, 33000)
            self.assertEqual(self._run(prev, cur, ("--max-shrink", "0.6")), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
