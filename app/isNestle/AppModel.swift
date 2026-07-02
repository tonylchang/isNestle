import SwiftUI

/// Holds the read-only database and the latest scan result.
///
/// Scanning is continuous: the camera stays live in the viewfinder and `result`
/// updates as new barcodes come into view, shown inline in the display area.
/// When **online lookup** is enabled, a barcode not in the bundle is resolved via
/// the free Open Food Facts API (off by default; see `OnlineLookup`).
enum DatasetUpdateState: Equatable {
    case idle, checking, upToDate, updated(String), failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    /// Injectable dependencies (network, database, persistence) so the model's
    /// logic — verdict application, stale-result guard, update throttling — is
    /// testable without the live bundle, OFF API, or standard defaults.
    struct Configuration {
        var openDatabase: () -> BarcodeDatabase?
        var resolveOnline: (String) async -> OnlineLookup.Hit?
        var checkAndUpdate: () async -> DatasetUpdater.Result
        var defaults: UserDefaults

        static var live: Configuration {
            Configuration(
                openDatabase: { DatasetStore.openActiveDatabase() },
                resolveOnline: { await OnlineLookup.resolve(barcode: $0) },
                checkAndUpdate: { await DatasetUpdater.checkAndUpdate() },
                defaults: .standard
            )
        }
    }

    private let configuration: Configuration

    /// Reopened after a dataset self-update, so it's a var (not let).
    private(set) var db: BarcodeDatabase?

    /// The latest scan result, shown in the display area. `nil` = nothing yet.
    @Published var result: OwnershipResult?
    /// Active boycott target, read from the dataset.
    @Published private(set) var target: BoycottTarget = .defaultTarget
    /// True while an online lookup is in flight (shows a "checking…" hint).
    @Published var isLookingUp = false
    /// Self-update status (shown in Settings).
    @Published var updateState: DatasetUpdateState = .idle

    /// Active dataset version (UTC CalVer timestamp), for display.
    var datasetVersion: String { DatasetStore.activeManifest?.version ?? "unknown" }
    /// Opt-in online fallback; persisted, off by default.
    @Published var onlineEnabled: Bool {
        didSet {
            configuration.defaults.set(onlineEnabled, forKey: Self.onlineKey)
            if !onlineEnabled {
                lookupTask?.cancel()
                isLookingUp = false
            }
        }
    }
    /// Active verdict theme; persisted, defaults to Minimal.
    @Published var theme: AppTheme {
        didSet { configuration.defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }

    private static let onlineKey = "onlineLookupEnabled"
    private static let themeKey = "appTheme"
    private static let lastUpdateCheckKey = "lastDatasetUpdateCheckDate"
    /// In-flight tasks, exposed read-only so tests can await them.
    private(set) var lookupTask: Task<Void, Never>?
    private(set) var updateCheckTask: Task<Void, Never>?

    init(configuration: Configuration = .live) {
        self.configuration = configuration
        db = configuration.openDatabase()
        target = db?.activeTarget() ?? .defaultTarget
        onlineEnabled = configuration.defaults.bool(forKey: Self.onlineKey)
        theme = AppTheme(rawValue: configuration.defaults.string(forKey: Self.themeKey) ?? "") ?? .minimal
        #if DEBUG
        // Dev hook: `-demoBarcode <code>` runs a full scan (including the online
        // path when online lookup is enabled) for screenshots / manual testing.
        if let i = CommandLine.arguments.firstIndex(of: "-demoBarcode"),
           i + 1 < CommandLine.arguments.count {
            handleScanned(CommandLine.arguments[i + 1])
        }
        #endif
        updateCheckTask = Task { await checkForDatasetUpdate() }   // daily self-update check on launch
    }

    /// Check the rolling release for a newer dataset; reopen the DB if installed.
    func checkForDatasetUpdate(force: Bool = false) async {
        guard updateState != .checking else { return }
        guard force || shouldCheckDatasetToday() else { return }
        updateState = .checking
        switch await configuration.checkAndUpdate() {
        case .upToDate:
            markDatasetUpdateChecked()
            updateState = .upToDate
        case .updated(let m):
            markDatasetUpdateChecked()
            db = configuration.openDatabase()   // reopen the freshly installed file
            target = db?.activeTarget() ?? .defaultTarget
            updateState = .updated(m.version)
        case .failed(let why):
            updateState = .failed(why)
        }
    }

    private func shouldCheckDatasetToday(now: Date = Date()) -> Bool {
        guard let last = configuration.defaults.object(forKey: Self.lastUpdateCheckKey) as? Date else {
            return true
        }
        return !Calendar.current.isDate(last, inSameDayAs: now)
    }

    private func markDatasetUpdateChecked(now: Date = Date()) {
        configuration.defaults.set(now, forKey: Self.lastUpdateCheckKey)
    }

    func handleScanned(_ barcode: String) {
        guard let db else { return }
        let barcode = BarcodeInput.trimmed(barcode)
        guard !barcode.isEmpty else { return }
        lookupTask?.cancel()
        let local = db.lookup(barcode: barcode)
        result = local
        isLookingUp = false

        // Only reach out when the bundle has no answer AND the user opted in.
        guard local.verdict == .unknown,
              onlineEnabled,
              BarcodeInput.networkBarcode(barcode) != nil else { return }
        isLookingUp = true
        lookupTask = Task { [weak self] in
            guard let resolve = self?.configuration.resolveOnline else { return }
            let hit = await resolve(barcode)
            guard !Task.isCancelled else { return }
            self?.applyOnline(hit, for: barcode)
        }
    }

    private func applyOnline(_ hit: OnlineLookup.Hit?, for barcode: String) {
        guard result?.query == barcode else { return }   // user moved on; a stale
        // completion must not touch state (incl. a newer lookup's spinner)
        isLookingUp = false
        guard onlineEnabled else { return }               // user opted out while the request was in flight
        guard let hit else { return }                     // network/parse failed; keep local result
        if let match = db?.matchTargetBrand(slugs: hit.brandSlugs) {
            if let exception = db?.coBrandException(for: match.brandSlug, brandSlugs: hit.brandSlugs) {
                switch exception.action {
                case .reattribute:
                    result = OwnershipResult(query: barcode, brandName: match.brandName, parent: nil,
                                             verdict: .notTarget, productName: hit.productName,
                                             manufacturer: exception.actualMaker ?? hit.owner,
                                             note: exception.note, fromOnline: true)
                case .exclude:
                    result = identifiedUnknown(hit, for: barcode, fallbackBrand: hit.brandsDisplay ?? match.brandName,
                                               note: exception.note)
                }
                return
            }
            result = OwnershipResult(query: barcode, brandName: match.brandName, parent: match.parent,
                                     verdict: .match, productName: hit.productName, fromOnline: true)
        } else if hit.brandsDisplay != nil || !hit.brandSlugs.isEmpty {
            // OFF can identify the product, but our target-owned brand list did
            // not match. Keep this as "unknown/no match" rather than asserting
            // the product is definitely not target-owned.
            result = identifiedUnknown(hit, for: barcode)
        }
        // else: OFF doesn't have it either → leave the local "no match" result as-is.
    }

    private func identifiedUnknown(_ hit: OnlineLookup.Hit, for barcode: String,
                                   fallbackBrand: String? = nil, note: String? = nil) -> OwnershipResult {
        let brand = hit.brandsDisplay
            ?? fallbackBrand
            ?? hit.brandSlugs.first.map { $0.replacingOccurrences(of: "-", with: " ").capitalized }
        return OwnershipResult(query: barcode, brandName: brand, parent: nil,
                               verdict: .unknown, productName: hit.productName,
                               manufacturer: hit.owner, note: note, fromOnline: true)
    }

    func clear() {
        lookupTask?.cancel()
        result = nil
        isLookingUp = false
    }
}
