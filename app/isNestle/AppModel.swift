import SwiftUI

/// Holds the read-only database and the current scan result.
@MainActor
final class AppModel: ObservableObject {
    let db: BarcodeDatabase?

    /// The latest verdict to present. `nil` means we're actively scanning.
    @Published var result: OwnershipResult?

    var isScanning: Bool { result == nil }

    init() {
        db = BarcodeDatabase()
        #if DEBUG
        // Dev hook: `-demoBarcode <code>` pre-loads a verdict so the verdict
        // screen can be exercised/screenshotted in the simulator (no camera).
        if let i = CommandLine.arguments.firstIndex(of: "-demoBarcode"),
           i + 1 < CommandLine.arguments.count, let db {
            result = db.lookup(barcode: CommandLine.arguments[i + 1])
        }
        #endif
    }

    func handleScanned(_ barcode: String) {
        guard result == nil, let db else { return }   // ignore repeats while a result is shown
        result = db.lookup(barcode: barcode)
    }

    /// Dismiss the current result and resume scanning.
    func resume() {
        result = nil
    }
}
