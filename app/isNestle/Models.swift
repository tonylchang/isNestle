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
    var manufacturer: String? = nil  // brand owner / maker (esp. for non-target products)
    var fromOnline: Bool = false     // resolved via the opt-in online lookup

    var id: String { query }

    /// Best human label for the scanned item: product name if known, else brand.
    var displayName: String? { productName ?? brandName }

    /// Ownership chain for display, most specific first (brand → parent/maker).
    /// For a target match this is brand → Nestlé; for a non-target product it's
    /// brand → manufacturer when known.
    var chain: [String] {
        [brandName, parent ?? manufacturer].compactMap { $0 }
    }

    /// Labeled fields for detailed themes (skips empties and obvious duplicates).
    var fields: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let productName { out.append(("Product", productName)) }
        if let brandName, brandName.caseInsensitiveCompare(productName ?? "") != .orderedSame {
            out.append(("Brand", brandName))
        }
        if let parent { out.append(("Parent", parent)) }
        else if let manufacturer, manufacturer.caseInsensitiveCompare(brandName ?? "") != .orderedSame {
            out.append(("Maker", manufacturer))
        }
        return out
    }
}

/// Verdict presentation theme (UI.md). The active theme is chosen in Settings;
/// adding a new case is the only change needed to add a theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case minimal
    case informational
    case receipt
    case tag

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .informational: return "Record"
        case .receipt: return "Receipt"
        case .tag: return "Tag"
        }
    }

    var blurb: String {
        switch self {
        case .minimal: return "Bold, color-flooded verdict — read it in a glance."
        case .informational: return "A calm, typographic ownership record."
        case .receipt: return "A checkout receipt, printed in monospace."
        case .tag: return "A shop price tag with the verdict as the price."
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
