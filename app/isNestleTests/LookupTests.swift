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

    func testDatasetUpdaterInstallsNewerVerifiedDataset() async throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let sqliteURL = try XCTUnwrap(URL(string: "https://example.com/isnestle.sqlite"))
        let sqliteData = try makeSQLiteFixture()
        let remote = manifest(version: "2026.07.01.0617",
                              sqliteURL: sqliteURL.absoluteString,
                              sqliteData: sqliteData,
                              brands: fixtureBrandCount,
                              barcodes: fixtureBarcodeCount)
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: .init(
            remoteManifestURL: remoteURL,
            store: config,
            data: { req in
                XCTAssertEqual(req.url, remoteURL)
                return (try JSONEncoder().encode(remote), self.httpResponse(for: remoteURL))
            },
            download: { req in
                XCTAssertEqual(req.url, sqliteURL)
                return (downloadURL, self.httpResponse(for: sqliteURL))
            }
        ))

        XCTAssertEqual(result, .updated(remote))
        XCTAssertEqual(DatasetStore.activeManifest(in: config), remote)
        XCTAssertEqual(try Data(contentsOf: config.downloadedDatabaseURL), sqliteData)
    }

    func testDatasetUpdaterRejectsChecksumMismatch() async throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let sqliteURL = try XCTUnwrap(URL(string: "https://example.com/isnestle.sqlite"))
        let sqliteData = Data("tampered sqlite data".utf8)
        let remote = DatasetManifest(version: "2026.07.01.0617",
                                     sqlite_url: sqliteURL.absoluteString,
                                     sqlite_sha256: String(repeating: "0", count: 64),
                                     sqlite_bytes: sqliteData.count,
                                     brands: 601,
                                     barcodes: 33424)
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: .init(
            remoteManifestURL: remoteURL,
            store: config,
            data: { _ in (try JSONEncoder().encode(remote), self.httpResponse(for: remoteURL)) },
            download: { _ in (downloadURL, self.httpResponse(for: sqliteURL)) }
        ))

        XCTAssertEqual(result, .failed("Checksum mismatch"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsCorruptDataset() async throws {
        // Correct size and checksum, but the bytes aren't a SQLite database —
        // must be rejected by the health check, not installed.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let sqliteData = Data("checksummed but not a database".utf8)
        let remote = manifest(version: "2026.07.01.0617", sqliteData: sqliteData)
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: .init(
            remoteManifestURL: remoteURL,
            store: config,
            data: { _ in (try JSONEncoder().encode(remote), self.httpResponse(for: remoteURL)) },
            download: { _ in (downloadURL, self.httpResponse(for: remoteURL)) }
        ))

        XCTAssertEqual(result, .failed("Dataset unreadable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
    }

    func testDatasetUpdaterRejectsCountMismatch() async throws {
        // A real database whose row counts don't match the manifest's claims.
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let sqliteData = try makeSQLiteFixture()
        let remote = manifest(version: "2026.07.01.0617", sqliteData: sqliteData,
                              brands: fixtureBrandCount + 5, barcodes: fixtureBarcodeCount)
        let downloadURL = try tempFile(data: sqliteData)

        let result = await DatasetUpdater.checkAndUpdate(configuration: .init(
            remoteManifestURL: remoteURL,
            store: config,
            data: { _ in (try JSONEncoder().encode(remote), self.httpResponse(for: remoteURL)) },
            download: { _ in (downloadURL, self.httpResponse(for: remoteURL)) }
        ))

        XCTAssertEqual(result, .failed("Dataset counts mismatch"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.downloadedDatabaseURL.path))
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

    func testDatasetUpdaterSkipsDownloadWhenRemoteIsNotNewer() async throws {
        let bundled = manifest(version: "2026.06.30.0302")
        let config = try makeStoreConfiguration(bundled: bundled)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        var downloadCalled = false

        let result = await DatasetUpdater.checkAndUpdate(configuration: .init(
            remoteManifestURL: remoteURL,
            store: config,
            data: { _ in (try JSONEncoder().encode(bundled), self.httpResponse(for: remoteURL)) },
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

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func httpResponse(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
