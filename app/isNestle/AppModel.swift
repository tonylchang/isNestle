import SwiftUI

/// Holds the read-only database and the latest scan result.
///
/// Scanning is continuous: the camera stays live in the viewfinder and `result`
/// updates as new barcodes come into view, shown inline in the display area.
/// When **online lookup** is enabled, a barcode not in the bundle is resolved via
/// the free Open Food Facts API (off by default; see `OnlineLookup`).
@MainActor
final class AppModel: ObservableObject {
    let db: BarcodeDatabase?

    /// The latest scan result, shown in the display area. `nil` = nothing yet.
    @Published var result: OwnershipResult?
    /// True while an online lookup is in flight (shows a "checking…" hint).
    @Published var isLookingUp = false
    /// Opt-in online fallback; persisted, off by default.
    @Published var onlineEnabled: Bool {
        didSet { UserDefaults.standard.set(onlineEnabled, forKey: Self.onlineKey) }
    }

    private static let onlineKey = "onlineLookupEnabled"
    private var lookupTask: Task<Void, Never>?

    init() {
        db = BarcodeDatabase()
        onlineEnabled = UserDefaults.standard.bool(forKey: Self.onlineKey)
        #if DEBUG
        // Dev hook: `-demoBarcode <code>` runs a full scan (including the online
        // path when online lookup is enabled) for screenshots / manual testing.
        if let i = CommandLine.arguments.firstIndex(of: "-demoBarcode"),
           i + 1 < CommandLine.arguments.count {
            handleScanned(CommandLine.arguments[i + 1])
        }
        #endif
    }

    func handleScanned(_ barcode: String) {
        guard let db else { return }
        lookupTask?.cancel()
        let local = db.lookup(barcode: barcode)
        result = local
        isLookingUp = false

        // Only reach out when the bundle has no answer AND the user opted in.
        guard local.verdict == .unknown, onlineEnabled else { return }
        isLookingUp = true
        lookupTask = Task { [weak self] in
            let hit = await OnlineLookup.resolve(barcode: barcode)
            self?.applyOnline(hit, for: barcode)
        }
    }

    private func applyOnline(_ hit: OnlineLookup.Hit?, for barcode: String) {
        isLookingUp = false
        guard result?.query == barcode else { return }   // user moved on; ignore
        guard let hit else { return }                     // network/parse failed; keep local result
        if let match = db?.matchTargetBrand(slugs: hit.brandSlugs) {
            result = OwnershipResult(query: barcode, brandName: match.brandName, parent: match.parent,
                                     verdict: .match, productName: hit.productName, fromOnline: true)
        } else if !hit.brandSlugs.isEmpty {
            // OFF knows the product and its brand isn't a target → confident "not Nestlé".
            let brand = hit.brandSlugs.first.map { $0.replacingOccurrences(of: "-", with: " ").capitalized }
            result = OwnershipResult(query: barcode, brandName: brand, parent: nil,
                                     verdict: .notTarget, productName: hit.productName, fromOnline: true)
        }
        // else: OFF doesn't have it either → leave the local "no match" result as-is.
    }

    func clear() {
        lookupTask?.cancel()
        result = nil
        isLookingUp = false
    }
}
