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
    var productName: String? = nil   // from the online fallback (OFF); local has none
    var fromOnline: Bool = false     // resolved via the opt-in online lookup

    var id: String { query }

    /// Best human label for the scanned item: product name if known, else brand.
    var displayName: String? { productName ?? brandName }

    /// Ownership chain for display, most specific first (brand → parent).
    var chain: [String] {
        [brandName, parent].compactMap { $0 }
    }
}

/// Verdict presentation theme (UI.md). The active theme is chosen in Settings;
/// adding a new case is the only change needed to add a theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case minimal
    case informational

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .informational: return "Informational"
        }
    }

    var blurb: String {
        switch self {
        case .minimal: return "Bold, color-flooded verdict — read it in a glance."
        case .informational: return "Calm, detailed card with the full ownership chain."
        }
    }
}

/// A brand row returned from manual search.
struct BrandHit: Identifiable, Equatable {
    var id: String { brandName }
    let brandName: String
    let parent: String
    let isTarget: Bool
}
