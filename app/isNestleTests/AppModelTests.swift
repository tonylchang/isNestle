import Foundation
import SQLite3
import XCTest
@testable import isNestle

/// Behavior tests for `AppModel`: verdict application from the online fallback,
/// the stale-result guard, lookup lifecycle, and the daily update-check throttle.
/// All dependencies are injected via `AppModel.Configuration`; the database is
/// the real bundled dataset (the test host is the app), the network is stubbed.
@MainActor
final class AppModelTests: XCTestCase {

    // Confirmed by the M0 spike / LookupTests: in the bundle vs not in the bundle.
    private let nestleBarcode = "3023290000953"    // Aero
    private let unknownBarcode = "7702535016688"   // Coca-Cola Fuze Tea

    // MARK: Local lookups

    func testLocalMatchDoesNotTriggerOnlineLookup() async {
        let model = makeModel(resolveOnline: { _ in
            XCTFail("online lookup must not run for a local match")
            return nil
        })
        model.onlineEnabled = true

        model.handleScanned(nestleBarcode)

        XCTAssertEqual(model.result?.verdict, .match)
        XCTAssertEqual(model.result?.parent, "Nestlé")
        XCTAssertFalse(model.isLookingUp)
        XCTAssertNil(model.lookupTask)
        await model.updateCheckTask?.value
    }

    func testUnknownBarcodeWithOnlineDisabledStaysLocal() {
        let model = makeModel(resolveOnline: { _ in
            XCTFail("online lookup must not run when the user has not opted in")
            return nil
        })
        XCTAssertFalse(model.onlineEnabled, "online lookup must default to off")

        model.handleScanned(unknownBarcode)

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertFalse(model.result?.fromOnline ?? true)
        XCTAssertFalse(model.isLookingUp)
        XCTAssertNil(model.lookupTask)
    }

    func testOnlineFallbackDoesNotRunForNonBarcodePayload() {
        let model = makeModel(resolveOnline: { _ in
            XCTFail("online lookup must not run for non-product-barcode payloads")
            return nil
        })
        model.onlineEnabled = true

        model.handleScanned("https://example.com/not-a-product-code")

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertFalse(model.isLookingUp)
        XCTAssertNil(model.lookupTask)
    }

    // MARK: Online fallback verdicts

    func testOnlineFallbackUpgradesToTargetMatch() async {
        let model = makeModel(resolveOnline: { _ in
            OnlineLookup.Hit(brandSlugs: ["coca-cola", "nestle"], productName: "Choc Bar",
                             brandsDisplay: "Nestlé", owner: nil)
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        XCTAssertTrue(model.isLookingUp)
        await model.lookupTask?.value

        XCTAssertEqual(model.result?.verdict, .match)
        XCTAssertEqual(model.result?.query, unknownBarcode)
        XCTAssertEqual(model.result?.parent, "Nestlé")
        XCTAssertEqual(model.result?.brandName, "Nestlé")     // from the bundled brand table
        XCTAssertEqual(model.result?.productName, "Choc Bar")
        XCTAssertTrue(model.result?.fromOnline ?? false)
        XCTAssertFalse(model.isLookingUp)
    }

    func testOnlineFallbackKeepsUnknownForNonTargetProduct() async {
        // OFF identifies the product but no slug maps to a target brand: the app
        // must stay honest — "no match", never a positive "not the target".
        let model = makeModel(resolveOnline: { _ in
            OnlineLookup.Hit(brandSlugs: ["coca-cola"], productName: "Fuze Tea",
                             brandsDisplay: "Coca-Cola", owner: "The Coca-Cola Company")
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        await model.lookupTask?.value

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertNil(model.result?.parent)
        XCTAssertEqual(model.result?.brandName, "Coca-Cola")
        XCTAssertEqual(model.result?.productName, "Fuze Tea")
        XCTAssertEqual(model.result?.manufacturer, "The Coca-Cola Company")
        XCTAssertTrue(model.result?.fromOnline ?? false)
    }

    func testOnlineFallbackWithNoHitKeepsLocalResult() async {
        let model = makeModel(resolveOnline: { _ in nil })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        await model.lookupTask?.value

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertNil(model.result?.brandName)
        XCTAssertFalse(model.result?.fromOnline ?? true)
        XCTAssertFalse(model.isLookingUp)
    }

    func testOnlineFallbackBrandNameFallsBackToCapitalizedSlug() async {
        let model = makeModel(resolveOnline: { _ in
            OnlineLookup.Hit(brandSlugs: ["some-unknown-brand"], productName: nil,
                             brandsDisplay: nil, owner: nil)
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        await model.lookupTask?.value

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertEqual(model.result?.brandName, "Some Unknown Brand")
        XCTAssertTrue(model.result?.fromOnline ?? false)
    }

    func testOnlineFallbackReattributesCoBrandException() async throws {
        let db = try makeDatabase(exceptionAction: "reattribute",
                                  actualMaker: "Hershey",
                                  note: "US KitKat is made under license by Hershey.")
        let model = makeModel(database: db, resolveOnline: { _ in
            OnlineLookup.Hit(brandSlugs: ["kitkat", "hershey-s"], productName: "KitKat Bar",
                             brandsDisplay: "KitKat, Hershey's", owner: "The Hershey Company")
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        await model.lookupTask?.value

        XCTAssertEqual(model.result?.verdict, .notTarget)
        XCTAssertEqual(model.result?.brandName, "KitKat")
        XCTAssertNil(model.result?.parent)
        XCTAssertEqual(model.result?.manufacturer, "Hershey")
        XCTAssertEqual(model.result?.note, "US KitKat is made under license by Hershey.")
        XCTAssertEqual(model.result?.productName, "KitKat Bar")
        XCTAssertTrue(model.result?.fromOnline ?? false)
    }

    func testOnlineFallbackExcludeExceptionStaysUnknown() async throws {
        let db = try makeDatabase(exceptionAction: "exclude",
                                  actualMaker: nil,
                                  note: "US Smarties is an unrelated brand.")
        let model = makeModel(database: db, resolveOnline: { _ in
            OnlineLookup.Hit(brandSlugs: ["kitkat", "hershey-s"], productName: "Excluded Bar",
                             brandsDisplay: "KitKat, Hershey's", owner: "Other Maker")
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        await model.lookupTask?.value

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertEqual(model.result?.brandName, "KitKat, Hershey's")
        XCTAssertEqual(model.result?.productName, "Excluded Bar")
        XCTAssertEqual(model.result?.manufacturer, "Other Maker")
        XCTAssertEqual(model.result?.note, "US Smarties is an unrelated brand.")
        XCTAssertTrue(model.result?.fromOnline ?? false)
    }

    // MARK: Stale results and cancellation

    func testStaleOnlineResultIsIgnoredAfterANewerScan() async {
        let gate = AsyncGate()
        let model = makeModel(resolveOnline: { _ in
            await gate.wait()
            return OnlineLookup.Hit(brandSlugs: ["nestle"], productName: "Stale Product",
                                    brandsDisplay: nil, owner: nil)
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)          // online lookup parked at the gate
        let staleLookup = model.lookupTask
        model.handleScanned(nestleBarcode)           // user moved on; local match
        XCTAssertEqual(model.result?.verdict, .match)
        XCTAssertFalse(model.isLookingUp)

        await gate.open()
        await staleLookup?.value

        XCTAssertEqual(model.result?.query, nestleBarcode, "stale hit must not overwrite the newer result")
        XCTAssertNil(model.result?.productName)
        XCTAssertFalse(model.result?.fromOnline ?? true)
    }

    func testStaleCompletionDoesNotClearSpinnerOfNewerLookup() async {
        // Scan two unknown barcodes back to back: when the first (stale) lookup
        // completes, the second is still in flight and its spinner must survive.
        let gate = AsyncGate()
        let model = makeModel(resolveOnline: { barcode in
            if barcode == "0000000000001" { return nil }   // stale one resolves first
            await gate.wait()
            return nil
        })
        model.onlineEnabled = true

        model.handleScanned("0000000000001")
        let staleLookup = model.lookupTask
        model.handleScanned(unknownBarcode)
        XCTAssertTrue(model.isLookingUp)

        await staleLookup?.value
        XCTAssertTrue(model.isLookingUp, "a stale completion must not clear the newer lookup's spinner")

        await gate.open()
        await model.lookupTask?.value
        XCTAssertFalse(model.isLookingUp)
    }

    func testOnlineResultIsIgnoredAfterLookupIsDisabled() async {
        let gate = AsyncGate()
        let model = makeModel(resolveOnline: { _ in
            await gate.wait()
            return OnlineLookup.Hit(brandSlugs: ["nestle"], productName: "Late Online Hit",
                                    brandsDisplay: nil, owner: nil)
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        let pending = model.lookupTask
        XCTAssertTrue(model.isLookingUp)

        model.onlineEnabled = false
        XCTAssertFalse(model.isLookingUp)

        await gate.open()
        await pending?.value

        XCTAssertEqual(model.result?.verdict, .unknown)
        XCTAssertFalse(model.result?.fromOnline ?? true)
        XCTAssertNil(model.result?.productName)
    }

    func testClearResetsResultAndPendingLookupIsDiscarded() async {
        let gate = AsyncGate()
        let model = makeModel(resolveOnline: { _ in
            await gate.wait()
            return OnlineLookup.Hit(brandSlugs: ["nestle"], productName: "Late",
                                    brandsDisplay: nil, owner: nil)
        })
        model.onlineEnabled = true

        model.handleScanned(unknownBarcode)
        let pending = model.lookupTask
        model.clear()
        XCTAssertNil(model.result)
        XCTAssertFalse(model.isLookingUp)

        await gate.open()
        await pending?.value
        XCTAssertNil(model.result, "a lookup completing after clear() must not resurrect a result")
        XCTAssertFalse(model.isLookingUp)
    }

    // MARK: Dataset update check throttle

    func testUpdateCheckRunsOnLaunchAndIsThrottledToDaily() async {
        var checkCount = 0
        let model = makeModel(checkAndUpdate: { checkCount += 1; return .upToDate })

        await model.updateCheckTask?.value
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(model.updateState, .upToDate)

        await model.checkForDatasetUpdate()          // same day → skipped
        XCTAssertEqual(checkCount, 1)

        await model.checkForDatasetUpdate(force: true)
        XCTAssertEqual(checkCount, 2)
    }

    func testFailedUpdateCheckIsNotMarkedAsCheckedForTheDay() async {
        var checkCount = 0
        let model = makeModel(checkAndUpdate: { checkCount += 1; return .failed("boom") })

        await model.updateCheckTask?.value
        XCTAssertEqual(model.updateState, .failed("boom"))
        XCTAssertEqual(checkCount, 1)

        await model.checkForDatasetUpdate()          // failure didn't consume the day
        XCTAssertEqual(checkCount, 2)
    }

    func testSuccessfulUpdateReopensDatabaseAndReportsVersion() async {
        var openCount = 0
        let manifest = DatasetManifest(version: "2026.07.02.0617", sqlite_url: "",
                                       sqlite_sha256: "", sqlite_bytes: 1, brands: 1, barcodes: 1)
        var configuration = makeConfiguration()
        configuration.openDatabase = { openCount += 1; return BarcodeDatabase() }
        configuration.checkAndUpdate = { .updated(manifest) }
        let model = AppModel(configuration: configuration)
        XCTAssertEqual(openCount, 1)

        await model.updateCheckTask?.value

        XCTAssertEqual(openCount, 2, "an installed update must reopen the database")
        XCTAssertEqual(model.updateState, .updated("2026.07.02.0617"))
        XCTAssertEqual(model.target.name, "Nestlé")
    }

    // MARK: Settings persistence

    func testOnlineEnabledAndThemePersistAcrossModels() async {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.onlineEnabled = true
        model.theme = .receipt
        await model.updateCheckTask?.value

        let reloaded = makeModel(defaults: defaults)
        XCTAssertTrue(reloaded.onlineEnabled)
        XCTAssertEqual(reloaded.theme, .receipt)
        await reloaded.updateCheckTask?.value
    }

    // MARK: Helpers

    private func makeModel(database: BarcodeDatabase? = nil,
                           defaults: UserDefaults? = nil,
                           resolveOnline: @escaping (String) async -> OnlineLookup.Hit? = { _ in nil },
                           checkAndUpdate: @escaping () async -> DatasetUpdater.Result = { .upToDate }) -> AppModel {
        AppModel(configuration: makeConfiguration(database: database,
                                                  defaults: defaults,
                                                  resolveOnline: resolveOnline,
                                                  checkAndUpdate: checkAndUpdate))
    }

    private func makeConfiguration(database: BarcodeDatabase? = nil,
                                   defaults: UserDefaults? = nil,
                                   resolveOnline: @escaping (String) async -> OnlineLookup.Hit? = { _ in nil },
                                   checkAndUpdate: @escaping () async -> DatasetUpdater.Result = { .upToDate }) -> AppModel.Configuration {
        AppModel.Configuration(
            openDatabase: { database ?? BarcodeDatabase() },   // real bundled dataset in the test host
            resolveOnline: resolveOnline,
            checkAndUpdate: checkAndUpdate,
            defaults: defaults ?? makeDefaults()
        )
    }

    /// A throwaway defaults suite so tests never touch (or inherit) the app's real settings.
    private func makeDefaults() -> UserDefaults {
        let name = "isnestle-appmodel-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeDatabase(exceptionAction: String, actualMaker: String?, note: String) throws -> BarcodeDatabase {
        let url = try tempDirectory().appendingPathComponent("fixture.sqlite")
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "AppModelTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not create fixture db"])
        }

        let sql = """
        CREATE TABLE brands (brand_slug TEXT PRIMARY KEY, brand_name TEXT NOT NULL,
                             parent TEXT NOT NULL, is_target INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE barcodes (barcode TEXT PRIMARY KEY, brand_slug TEXT NOT NULL, source TEXT);
        CREATE TABLE exceptions (brand_slug TEXT, scope_type TEXT, scope_value TEXT,
                                 actual_maker TEXT, action TEXT, note TEXT, source_url TEXT);
        INSERT INTO brands VALUES ('kitkat', 'KitKat', 'Nestlé', 1);
        INSERT INTO barcodes VALUES ('1111111111111', 'kitkat', 'fixture');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "AppModelTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not populate fixture db"])
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let insert = "INSERT INTO exceptions VALUES ('kitkat', 'co_brand', 'hershey-s', ?, ?, ?, 'https://example.com');"
        guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "AppModelTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "could not prepare exception insert"])
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let actualMaker {
            sqlite3_bind_text(stmt, 1, actualMaker, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, exceptionAction, -1, transient)
        sqlite3_bind_text(stmt, 3, note, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "AppModelTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "could not insert exception"])
        }

        return try XCTUnwrap(BarcodeDatabase(url: url), "fixture database should load")
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isnestle-appmodel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// A one-shot async gate: `wait()` suspends callers until `open()` releases them.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
