import CryptoKit
import Foundation
import SQLite3
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

    func testActiveTargetComesFromBundledDataset() throws {
        let db = try makeDB()
        XCTAssertEqual(db.activeTarget().name, "Nestlé")
    }

    func testIntentVerdictSummaries() throws {
        let db = try makeDB()
        let target = db.activeTarget()

        let match = db.lookup(barcode: "3023290000953")   // Aero — known match
        let matchSummary = IntentVerdict.summary(for: match, target: target)
        XCTAssertTrue(matchSummary.contains(target.name))
        XCTAssertTrue(matchSummary.contains("made by"), "match summary should explain the verdict")

        let unknown = db.lookup(barcode: "7702535016688") // Coca-Cola — not in dataset
        let unknownSummary = IntentVerdict.summary(for: unknown, target: target)
        XCTAssertTrue(unknownSummary.contains("No match"))
        XCTAssertTrue(unknownSummary.contains("isn’t proof"), "unknown summary must stay hedged")

        let hit = try XCTUnwrap(db.searchBrands(query: "Nescafé", limit: 1).first)
        XCTAssertEqual(IntentVerdict.summary(for: hit, query: "Nescafé", target: target),
                       "\(hit.brandName) is made by \(hit.parent).")
        XCTAssertTrue(IntentVerdict.summary(for: nil, query: "zzz", target: target)
            .contains("No \(target.name) match"))
    }

    func testCheckIntentsPerformOffline() async throws {
        // Smoke test: both intents resolve against the bundled dataset without
        // touching the network (intents are offline-only by design).
        let barcodeIntent = CheckBarcodeIntent()
        barcodeIntent.barcode = "3023290000953"
        _ = try await barcodeIntent.perform()

        let brandIntent = CheckBrandIntent()
        brandIntent.brand = "Nescafé"
        _ = try await brandIntent.perform()
    }

    func testMatchTargetBrandFromSlugs() throws {
        let db = try makeDB()
        // OFF would return brands_tags like these; the online fallback maps them.
        XCTAssertNotNil(db.matchTargetBrand(slugs: ["coca-cola", "nestle"]),
                        "nestle slug should map to a target brand")
        XCTAssertNil(db.matchTargetBrand(slugs: ["coca-cola", "pepsi"]),
                     "no target brand among these slugs")
    }

    func testOldSchemaFixtureStillLooksUpExactRows() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        INSERT INTO brands VALUES ('nestle', 'Nestlé', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('1111111111111', 'nestle', 'fixture');
        """)

        let exact = db.lookup(barcode: "1111111111111")
        XCTAssertEqual(exact.verdict, .match)
        XCTAssertEqual(exact.brandName, "Nestlé")
        XCTAssertEqual(exact.matchBasis, .exact)

        let missing = db.lookup(barcode: "0999999999999")
        XCTAssertEqual(missing.verdict, .unknown)
    }

    func testExactLookupTriesUPCAAndEAN13Variants() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        INSERT INTO brands VALUES ('nestle', 'Nestlé', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('0123456789012', 'nestle', 'fixture'),
                                    ('888888888888', 'nestle', 'fixture');
        """)

        let padded = db.lookup(barcode: "123456789012")
        XCTAssertEqual(padded.verdict, .match)
        XCTAssertEqual(padded.query, "123456789012")

        let depadded = db.lookup(barcode: "0888888888888")
        XCTAssertEqual(depadded.verdict, .match)
        XCTAssertEqual(depadded.query, "0888888888888")
    }

    func testOverrideRowReturnsNotTargetMakerAndNote() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT,
                               maker_override TEXT, override_note TEXT, match_basis TEXT,
                               evidence_count INTEGER);
        INSERT INTO brands VALUES ('kitkat', 'KitKat', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('034000002004', 'kitkat', 'fixture', 'Hershey',
                                    'Made under license by Hershey in the US.', 'exact', 2);
        """)

        let result = db.lookup(barcode: "034000002004")

        XCTAssertEqual(result.verdict, .notTarget)
        XCTAssertEqual(result.brandName, "KitKat")
        XCTAssertNil(result.parent)
        XCTAssertEqual(result.manufacturer, "Hershey")
        XCTAssertEqual(result.note, "Made under license by Hershey in the US.")
        XCTAssertEqual(result.evidenceCount, 2)
        XCTAssertTrue(result.fields.contains { $0.label == "Note" && $0.value.contains("Hershey") })
    }

    func testCoBrandExceptionLookupReadsOptionalTable() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        CREATE TABLE exceptions (brand_slug TEXT, scope_type TEXT, scope_value TEXT,
                                 actual_maker TEXT, action TEXT, note TEXT, source_url TEXT);
        INSERT INTO brands VALUES ('kitkat', 'KitKat', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('1111111111111', 'kitkat', 'fixture');
        INSERT INTO exceptions VALUES ('kitkat', 'co_brand', 'hershey-s', 'Hershey',
                                       'reattribute', 'US KitKat is made by Hershey.', 'https://example.com');
        """)

        let exception = db.coBrandException(for: "kitkat", brandSlugs: ["kitkat", "hershey-s"])

        XCTAssertEqual(exception?.action, .reattribute)
        XCTAssertEqual(exception?.actualMaker, "Hershey")
        XCTAssertEqual(exception?.note, "US KitKat is made by Hershey.")
        XCTAssertNil(db.coBrandException(for: "kitkat", brandSlugs: ["kitkat"]))
    }

    func testPrefixLookupUsesLongestTargetPrefix() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        CREATE TABLE prefixes (prefix TEXT PRIMARY KEY, parent TEXT, is_target INTEGER,
                               evidence_count INTEGER, source TEXT);
        INSERT INTO brands VALUES ('nestle', 'Nestlé', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('9999999999999', 'nestle', 'fixture');
        INSERT INTO prefixes VALUES ('012345', 'Nestlé', 1, 12, 'fixture'),
                                    ('0123456', 'Nestlé', 1, 24, 'fixture');
        """)

        let result = db.lookup(barcode: "123456789012")

        XCTAssertEqual(result.verdict, .match)
        XCTAssertEqual(result.parent, "Nestlé")
        XCTAssertEqual(result.matchBasis, .inferredFromPrefix)
        XCTAssertEqual(result.evidenceCount, 24)
        XCTAssertNil(result.brandName)
    }

    func testExactBarcodeMatchWinsOverPrefix() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        CREATE TABLE prefixes (prefix TEXT PRIMARY KEY, parent TEXT, is_target INTEGER,
                               evidence_count INTEGER, source TEXT);
        INSERT INTO brands VALUES ('cola', 'Cola', 'The Cola Company', 0),
                                  ('nestle', 'Nestlé', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('0123456789012', 'cola', 'fixture');
        INSERT INTO prefixes VALUES ('012345', 'Nestlé', 1, 20, 'fixture');
        """)

        let result = db.lookup(barcode: "0123456789012")

        XCTAssertEqual(result.verdict, .notTarget)
        XCTAssertEqual(result.brandName, "Cola")
        XCTAssertEqual(result.parent, "The Cola Company")
        XCTAssertEqual(result.matchBasis, .exact)
        XCTAssertNil(result.evidenceCount)
    }

    func testPrefixLookupSkipsHardExcludedRanges() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        CREATE TABLE prefixes (prefix TEXT PRIMARY KEY, parent TEXT, is_target INTEGER,
                               evidence_count INTEGER, source TEXT);
        INSERT INTO brands VALUES ('nestle', 'Nestlé', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('9999999999999', 'nestle', 'fixture');
        INSERT INTO prefixes VALUES ('020000', 'Nestlé', 1, 12, 'fixture'),
                                    ('978123', 'Nestlé', 1, 12, 'fixture');
        """)

        XCTAssertEqual(db.lookup(barcode: "200001234567").verdict, .unknown)
        XCTAssertEqual(db.lookup(barcode: "9781234567897").verdict, .unknown)
    }

    func testPrefixExceptionSuppressesInferredMatch() throws {
        let db = try makeDatabase(sql: """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        CREATE TABLE prefixes (prefix TEXT PRIMARY KEY, parent TEXT, is_target INTEGER,
                               evidence_count INTEGER, source TEXT);
        CREATE TABLE exceptions (brand_slug TEXT, scope_type TEXT, scope_value TEXT,
                                 actual_maker TEXT, action TEXT, note TEXT, source_url TEXT);
        INSERT INTO brands VALUES ('nestle', 'Nestlé', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('9999999999999', 'nestle', 'fixture');
        INSERT INTO prefixes VALUES ('003400', 'Nestlé', 1, 20, 'fixture');
        INSERT INTO exceptions VALUES ('kitkat', 'prefix', '034000', 'Hershey',
                                       'reattribute', 'Hershey prefix.', 'https://example.com');
        """)

        XCTAssertEqual(db.lookup(barcode: "034000002004").verdict, .unknown)
    }

    func testContributionURLAllowsOnlyBarcodeUnknowns() {
        let url = OpenFoodFactsContribution.addProductURL(barcode: " 1234567890123 ")
        XCTAssertEqual(url?.absoluteString,
                       "https://world.openfoodfacts.org/cgi/product.pl?type=add&code=1234567890123")
        XCTAssertNil(OpenFoodFactsContribution.addProductURL(barcode: "123 45&x=%"))
        XCTAssertFalse(OpenFoodFactsContribution.looksLikeBarcode("1234567"))
        XCTAssertFalse(OpenFoodFactsContribution.looksLikeBarcode("１２３４５６７８"))
        XCTAssertTrue(OpenFoodFactsContribution.looksLikeBarcode("12345678"))

        let unknown = OwnershipResult(query: "1234567890123", brandName: nil, parent: nil, verdict: .unknown)
        XCTAssertEqual(unknown.openFoodFactsContributionURL?.absoluteString,
                       "https://world.openfoodfacts.org/cgi/product.pl?type=add&code=1234567890123")

        let nonBarcodeUnknown = OwnershipResult(query: "not-a-barcode", brandName: nil, parent: nil,
                                                verdict: .unknown)
        XCTAssertNil(nonBarcodeUnknown.openFoodFactsContributionURL)

        let match = OwnershipResult(query: "1234567890123", brandName: "Nestlé", parent: "Nestlé",
                                    verdict: .match)
        XCTAssertNil(match.openFoodFactsContributionURL)
    }

    func testPrefixHedgeCopyIncludesLikelyAndEvidence() {
        let result = OwnershipResult(query: "1234567890123", brandName: nil, parent: "Nestlé",
                                     verdict: .match, matchBasis: .inferredFromPrefix,
                                     evidenceCount: 10)
        let style = VerdictStyle(.match, target: .defaultTarget)

        XCTAssertEqual(style.headline(result), "LIKELY NESTLÉ")
        XCTAssertEqual(style.shortWord(result), "Likely Nestlé")
        XCTAssertTrue(style.detail(result).contains("10 known products"))
        XCTAssertTrue(result.fields.contains { $0.label == "Basis" && $0.value == "Manufacturer prefix" })
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
        XCTAssertTrue(m("2026.07.01.0000").isNewer(than: m("2026.06.28.2359")))
        XCTAssertFalse(m("2026.06.28.0000").isNewer(than: m("2026.06.28.0000")))
        XCTAssertFalse(m("2026.06.27.2359").isNewer(than: m("2026.06.28.0000")))
    }

    func testDatasetStoreUsesBundledDatasetWhenNoDownloadExists() throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)

        XCTAssertEqual(DatasetStore.activeManifest(in: config), bundled)
        XCTAssertEqual(DatasetStore.activeDatabaseURL(in: config), config.bundledDatabaseURL)
    }

    func testDatasetStoreUsesDownloadedDatasetWhenItIsNewer() throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let downloaded = manifest(version: "2026.07.01.0617")
        let config = try makeStoreConfiguration(bundled: bundled, downloaded: downloaded)

        XCTAssertEqual(DatasetStore.activeManifest(in: config), downloaded)
        XCTAssertEqual(DatasetStore.activeDatabaseURL(in: config), config.downloadedDatabaseURL)
    }

    func testDatasetStoreUsesBundledDatasetWhenBundleIsNewerThanDownload() throws {
        let bundled = manifest(version: "2026.07.01.0617")
        let downloaded = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled, downloaded: downloaded)

        XCTAssertEqual(DatasetStore.activeManifest(in: config), bundled)
        XCTAssertEqual(DatasetStore.activeDatabaseURL(in: config), config.bundledDatabaseURL)
    }

    func testDatasetUpdaterInstallsNewerSignedVerifiedDataset() async throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let sqliteData = try makeSQLiteFixture()
        let remote = try sign(manifest(version: "2026.07.01.0617",
                                       sqliteData: sqliteData,
                                       brands: fixtureBrandCount,
                                       barcodes: fixtureBarcodeCount))
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote,
            download: { req in
                XCTAssertEqual(req.url?.absoluteString, remote.manifest.sqlite_url)
                return (downloadURL, self.httpResponse(for: try XCTUnwrap(req.url)))
            }
        ))

        XCTAssertEqual(result, .updated(remote.manifest))
        XCTAssertEqual(DatasetStore.activeManifest(in: config), remote.manifest)
        XCTAssertEqual(try Data(contentsOf: config.downloadedDatabaseURL), sqliteData)
    }

    func testDatasetUpdaterRejectsChecksumMismatch() async throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let sqliteData = Data("tampered sqlite data".utf8)
        let remote = try sign(DatasetManifest(version: "2026.07.01.0617",
                                              sqlite_url: "https://example.com/isnestle.sqlite",
                                              sqlite_sha256: String(repeating: "0", count: 64),
                                              sqlite_bytes: sqliteData.count,
                                              brands: 601,
                                              barcodes: 33424))
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote,
            download: { _ in (downloadURL, self.httpResponse(for: Self.testManifestURL)) }
        ))

        XCTAssertEqual(result, .failed("Checksum mismatch"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsCorruptDataset() async throws {
        // Correct size and checksum, but the bytes aren't a SQLite database —
        // must be rejected by the health check, not installed.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let sqliteData = Data("checksummed but not a database".utf8)
        let remote = try sign(manifest(version: "2026.07.01.0617", sqliteData: sqliteData))
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote,
            download: { _ in (downloadURL, self.httpResponse(for: Self.testManifestURL)) }
        ))

        XCTAssertEqual(result, .failed("Dataset unreadable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsCountMismatch() async throws {
        // A real database whose row counts don't match the manifest's claims.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let sqliteData = try makeSQLiteFixture()
        let remote = try sign(manifest(version: "2026.07.01.0617", sqliteData: sqliteData,
                                       brands: fixtureBrandCount + 5, barcodes: fixtureBarcodeCount))
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote,
            download: { _ in (downloadURL, self.httpResponse(for: Self.testManifestURL)) }
        ))

        XCTAssertEqual(result, .failed("Dataset counts mismatch"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsMissingSignature() async throws {
        // Newer manifest but the signature asset 404s — nothing may install.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remote = try sign(manifest(version: "2026.07.01.0617"))

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote, signatureStatus: 404
        ))

        XCTAssertEqual(result, .failed("Signature missing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsUntrustedSignature() async throws {
        // Release tampering: manifest signed by a key the app doesn't trust.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remote = try sign(manifest(version: "2026.07.01.0617"))
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try attacker.signature(for: remote.bytes)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote, signatureData: forged
        ))

        XCTAssertEqual(result, .failed("Signature invalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsSignatureOverDifferentManifest() async throws {
        // A genuine signature for some OTHER manifest must not authenticate this
        // one (replaying a signature across releases).
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remote = try sign(manifest(version: "2026.07.01.0617"))
        let other = try sign(manifest(version: "2026.07.02.0617"), with: remote.signingKey)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote, signatureData: other.signature
        ))

        XCTAssertEqual(result, .failed("Signature invalid"))
    }

    func testDatasetUpdaterAcceptsStandbyKeySignature() async throws {
        // Rotation path: a manifest signed by the second trusted key installs.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let sqliteData = try makeSQLiteFixture()
        let standby = Curve25519.Signing.PrivateKey()
        let remote = try sign(manifest(version: "2026.07.01.0617",
                                       sqliteData: sqliteData,
                                       brands: fixtureBrandCount,
                                       barcodes: fixtureBarcodeCount),
                              with: standby)
        let retiredPrimary = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: updaterConfiguration(
            store: config, remote: remote,
            trustedKeys: [retiredPrimary, standby.publicKey.rawRepresentation],
            download: { _ in (downloadURL, self.httpResponse(for: Self.testManifestURL)) }
        ))

        XCTAssertEqual(result, .updated(remote.manifest))
    }

    func testBakedInTrustedKeysAreWellFormed() {
        // A typo in the hex constants must fail here, not at runtime.
        let keys = DatasetManifest.trustedPublicKeys
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 2, "primary and standby must differ")
        for key in keys {
            XCTAssertEqual(key.count, 32)
            XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: key))
        }
    }

    func testDataHexEncodedInit() {
        XCTAssertEqual(Data(hexEncoded: "00ff10"), Data([0x00, 0xff, 0x10]))
        XCTAssertEqual(Data(hexEncoded: "ABCD"), Data([0xab, 0xcd]))
        XCTAssertEqual(Data(hexEncoded: ""), Data())
        XCTAssertNil(Data(hexEncoded: "abc"))     // odd length
        XCTAssertNil(Data(hexEncoded: "zz"))      // not hex
    }

    func testOpenActiveDatabaseFallsBackToBundleWhenDownloadIsCorrupt() throws {
        // A corrupt downloaded copy (newer manifest, garbage file) must not brick
        // lookups: fall back to the bundled dataset and discard the download so
        // the next daily check re-downloads.
        let bundled = manifest(version: "2026.06.30.0302")
        let downloaded = manifest(version: "2026.07.01.0617")
        let config = try makeStoreConfiguration(bundled: bundled,
                                                downloaded: downloaded,
                                                bundledData: makeSQLiteFixture(),
                                                downloadedData: Data("corrupt".utf8))

        XCTAssertEqual(DatasetStore.activeDatabaseURL(in: config), config.downloadedDatabaseURL)
        let db = try XCTUnwrap(DatasetStore.openActiveDatabase(in: config))
        XCTAssertEqual(db.counts().brands, fixtureBrandCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedManifestURL.path))
        XCTAssertEqual(DatasetStore.activeManifest(in: config), bundled)
    }

    func testDatasetUpdaterSkipsSignatureAndDownloadWhenRemoteIsNotNewer() async throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remote = try sign(bundled)
        var downloadCalled = false

        let result = await DatasetUpdater.checkAndUpdate(configuration: .init(
            remoteManifestURL: Self.testManifestURL,
            remoteSignatureURL: Self.testSignatureURL,
            trustedKeys: remote.trustedKeys,
            store: config,
            data: { req in
                XCTAssertEqual(req.url, Self.testManifestURL,
                               "the signature must not be fetched on the up-to-date path")
                return (remote.bytes, self.httpResponse(for: Self.testManifestURL))
            },
            download: { _ in
                downloadCalled = true
                throw URLError(.badServerResponse)
            }
        ))

        XCTAssertEqual(result, .upToDate)
        XCTAssertFalse(downloadCalled)
    }

    private func manifest(version: String,
                          sqliteURL: String = "https://example.com/isnestle.sqlite",
                          sqliteData: Data = Data("sqlite".utf8),
                          brands: Int = 601,
                          barcodes: Int = 33424) -> DatasetManifest {
        DatasetManifest(version: version,
                        sqlite_url: sqliteURL,
                        sqlite_sha256: sha256(sqliteData),
                        sqlite_bytes: sqliteData.count,
                        brands: brands,
                        barcodes: barcodes)
    }

    private static let testManifestURL = URL(string: "https://example.com/manifest.json")!
    private static let testSignatureURL = URL(string: "https://example.com/manifest.json.sig")!

    /// A remote manifest plus the exact bytes the updater will see and their
    /// Ed25519 signature — what the daily workflow publishes.
    private struct SignedManifest {
        let manifest: DatasetManifest
        let bytes: Data
        let signature: Data
        let signingKey: Curve25519.Signing.PrivateKey
        var trustedKeys: [Data] { [signingKey.publicKey.rawRepresentation] }
    }

    private func sign(_ manifest: DatasetManifest,
                      with key: Curve25519.Signing.PrivateKey = .init()) throws -> SignedManifest {
        let bytes = try JSONEncoder().encode(manifest)
        return SignedManifest(manifest: manifest, bytes: bytes,
                              signature: try key.signature(for: bytes), signingKey: key)
    }

    /// Updater configuration serving a signed remote manifest; the signature
    /// response is overridable to simulate tampering or a missing asset.
    private func updaterConfiguration(store: DatasetStoreConfiguration,
                                      remote: SignedManifest,
                                      trustedKeys: [Data]? = nil,
                                      signatureData: Data? = nil,
                                      signatureStatus: Int = 200,
                                      download: @escaping (URLRequest) async throws -> (URL, URLResponse) = { _ in
                                          throw URLError(.badServerResponse)
                                      }) -> DatasetUpdater.Configuration {
        .init(
            remoteManifestURL: Self.testManifestURL,
            remoteSignatureURL: Self.testSignatureURL,
            trustedKeys: trustedKeys ?? remote.trustedKeys,
            store: store,
            data: { req in
                if req.url == Self.testManifestURL {
                    return (remote.bytes, self.httpResponse(for: Self.testManifestURL))
                }
                XCTAssertEqual(req.url, Self.testSignatureURL)
                return (signatureData ?? remote.signature,
                        self.httpResponse(for: Self.testSignatureURL, status: signatureStatus))
            },
            download: download
        )
    }

    private func makeStoreConfiguration(bundled: DatasetManifest,
                                        downloaded: DatasetManifest? = nil,
                                        bundledData: Data = Data("bundled sqlite".utf8),
                                        downloadedData: Data = Data("downloaded sqlite".utf8)) throws -> DatasetStoreConfiguration {
        let root = try tempDirectory()
        let bundledDB = root.appendingPathComponent("bundle.sqlite")
        let bundledManifest = root.appendingPathComponent("bundle_manifest.json")
        let appSupport = root.appendingPathComponent("ApplicationSupport")
        try bundledData.write(to: bundledDB)
        try JSONEncoder().encode(bundled).write(to: bundledManifest)

        if let downloaded {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try downloadedData.write(to: appSupport.appendingPathComponent("isnestle.sqlite"))
            try JSONEncoder().encode(downloaded).write(to: appSupport.appendingPathComponent("dataset_manifest.json"))
        }

        return DatasetStoreConfiguration(bundledDatabaseURL: bundledDB,
                                         bundledManifestURL: bundledManifest,
                                         appSupportDirectory: appSupport)
    }

    /// Row counts baked into `makeSQLiteFixture()`.
    private let fixtureBrandCount = 2
    private let fixtureBarcodeCount = 3

    /// A real, minimal dataset SQLite (schema.sql shape) as raw bytes, so tests
    /// can exercise the updater's health check with an installable file.
    private func makeSQLiteFixture() throws -> Data {
        let url = try tempDirectory().appendingPathComponent("fixture.sqlite")
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "LookupTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not create fixture db"])
        }
        let sql = """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        INSERT INTO brands VALUES ('nestle', 'Nestlé', 'Nestlé', 1), ('kitkat', 'KitKat', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('1111111111111', 'nestle', 'test'),
                                    ('2222222222222', 'kitkat', 'test'),
                                    ('3333333333333', 'kitkat', 'test');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LookupTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not populate fixture db"])
        }
        sqlite3_close(db)
        db = nil
        return try Data(contentsOf: url)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isnestle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func tempFile(data: Data) throws -> URL {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    private func makeDatabase(sql: String) throws -> BarcodeDatabase {
        let url = try makeSQLiteDatabase(sql: sql)
        return try XCTUnwrap(BarcodeDatabase(url: url), "fixture database should load")
    }

    private func makeSQLiteDatabase(sql: String) throws -> URL {
        let url = try tempDirectory().appendingPathComponent("fixture.sqlite")
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "LookupTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "could not create fixture db"])
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LookupTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "could not populate fixture db"])
        }
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func httpResponse(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
