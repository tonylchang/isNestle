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
import tempfile
import unittest
from pathlib import Path

import build_barcodes
import build_brands
import check_counts
import common


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
