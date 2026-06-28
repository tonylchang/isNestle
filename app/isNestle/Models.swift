import Foundation

/// The active boycott target. Data-driven by design (see PURPOSE.md / STACK.md):
/// the target is a value, not hard-coded logic, so supporting other companies
/// later is a data change, not a code change.
enum Target {
    static let name = "Nestlé"
}

/// The possible outcomes of a lookup.
///
/// With a *target-only* dataset (M0 catalogues Nestlé barcodes only), M1 emits
/// `.match` or `.unknown`. `.notTarget` is reserved for when a comprehensive
/// product database lets us positively confirm a product is NOT the target —
/// see FINDINGS.md.
enum Verdict: Equatable {
    case match       // made by the active target (Nestlé)
    case notTarget   // confirmed not the target
    case unknown     // barcode / brand not in the dataset
}

/// Result of resolving a barcode (or brand) to an owning company.
struct OwnershipResult: Identifiable, Equatable {
    let query: String          // the barcode or brand that was looked up
    let brandName: String?
    let parent: String?        // e.g. "Nestlé"
    let verdict: Verdict

    var id: String { query }

    /// Ownership chain for display, most specific first (brand → parent).
    var chain: [String] {
        [brandName, parent].compactMap { $0 }
    }
}

/// A brand row returned from manual search.
struct BrandHit: Identifiable, Equatable {
    var id: String { brandName }
    let brandName: String
    let parent: String
    let isTarget: Bool
}
