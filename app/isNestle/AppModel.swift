import SwiftUI

/// Holds the read-only database and the latest scan result.
///
/// Scanning is continuous: the camera stays live in the viewfinder and `result`
/// updates as new barcodes come into view, shown inline in the display area.
@MainActor
final class AppModel: ObservableObject {
    let db: BarcodeDatabase?

    /// The latest scan result, shown in the display area. `nil` = nothing yet.
    @Published var result: OwnershipResult?

    init() {
        db = BarcodeDatabase()
        #if DEBUG
        // Dev hook: `-demoBarcode <code>` pre-loads a verdict for screenshots.
        if let i = CommandLine.arguments.firstIndex(of: "-demoBarcode"),
           i + 1 < CommandLine.arguments.count, let db {
            result = db.lookup(barcode: CommandLine.arguments[i + 1])
        }
        #endif
    }

    func handleScanned(_ barcode: String) {
        guard let db else { return }
        result = db.lookup(barcode: barcode)
    }

    func clear() { result = nil }
}
