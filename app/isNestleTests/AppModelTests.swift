import Foundation
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

    private func makeModel(defaults: UserDefaults? = nil,
                           resolveOnline: @escaping (String) async -> OnlineLookup.Hit? = { _ in nil },
                           checkAndUpdate: @escaping () async -> DatasetUpdater.Result = { .upToDate }) -> AppModel {
        AppModel(configuration: makeConfiguration(defaults: defaults,
                                                  resolveOnline: resolveOnline,
                                                  checkAndUpdate: checkAndUpdate))
    }

    private func makeConfiguration(defaults: UserDefaults? = nil,
                                   resolveOnline: @escaping (String) async -> OnlineLookup.Hit? = { _ in nil },
                                   checkAndUpdate: @escaping () async -> DatasetUpdater.Result = { .upToDate }) -> AppModel.Configuration {
        AppModel.Configuration(
            openDatabase: { BarcodeDatabase() },   // real bundled dataset in the test host
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
