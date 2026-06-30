import XCTest
@testable import isNestle

/// Mirrors the Milestone 0 Python spike (test_spike.py) in the iOS runtime:
/// verifies the bundled SQLite loads and the lookup chain is correct.
final class LookupTests: XCTestCase {

    private func makeDB() throws -> BarcodeDatabase {
        try XCTUnwrap(BarcodeDatabase(), "bundled isnestle.sqlite should load from the app bundle")
    }

    func testKnownNestleBarcodesResolveToNestle() throws {
        let db = try makeDB()
        // Confirmed present in the dataset by the M0 spike (Aero, Milkybar).
        for code in ["3023290000953", "8445290461803"] {
            let r = db.lookup(barcode: code)
            XCTAssertEqual(r.verdict, .match, "\(code) should be a Nestlé match")
            XCTAssertEqual(r.parent, "Nestlé")
            XCTAssertNotNil(r.brandName)
        }
    }

    func testNonNestleBarcodeIsUnknown() throws {
        let db = try makeDB()
        // Coca-Cola Fuze Tea — not in the Nestlé-only dataset.
        XCTAssertEqual(db.lookup(barcode: "7702535016688").verdict, .unknown)
    }

    func testBrandSearchFindsNescafe() throws {
        let db = try makeDB()
        let hits = db.searchBrands(query: "Nesc")
        XCTAssertFalse(hits.isEmpty, "expected brand matches for 'Nesc'")
        XCTAssertTrue(hits.allSatisfy { $0.isTarget }, "all dataset brands map to the target")
    }

    func testMatchTargetBrandFromSlugs() throws {
        let db = try makeDB()
        // OFF would return brands_tags like these; the online fallback maps them.
        XCTAssertNotNil(db.matchTargetBrand(slugs: ["coca-cola", "nestle"]),
                        "nestle slug should map to a target brand")
        XCTAssertNil(db.matchTargetBrand(slugs: ["coca-cola", "pepsi"]),
                     "no target brand among these slugs")
    }

    func testCountsAreHealthy() throws {
        let db = try makeDB()
        let c = db.counts()
        XCTAssertGreaterThan(c.brands, 100)
        XCTAssertGreaterThan(c.barcodes, 1000)
    }

    func testBundledManifestLoads() throws {
        let m = try XCTUnwrap(DatasetStore.bundledManifest, "dataset_manifest.json should be bundled")
        XCTAssertFalse(m.version.isEmpty)
        XCTAssertGreaterThan(m.sqlite_bytes, 0)
        XCTAssertEqual(m.sqlite_sha256.count, 64)
    }

    func testManifestVersionComparison() {
        func m(_ v: String) -> DatasetManifest {
            DatasetManifest(version: v, sqlite_url: "", sqlite_sha256: "", sqlite_bytes: 1, brands: 1, barcodes: 1)
        }
        XCTAssertTrue(m("2026.06.28.1200").isNewer(than: m("2026.06.28.0617")))
        XCTAssertFalse(m("2026.06.28.0617").isNewer(than: m("2026.06.28.0617")))
        XCTAssertTrue(m("2026.07.01").isNewer(than: m("2026.06.28")))
        XCTAssertFalse(m("2026.06.28").isNewer(than: m("2026.06.28")))
        XCTAssertFalse(m("2026.06.27").isNewer(than: m("2026.06.28")))
    }
}
