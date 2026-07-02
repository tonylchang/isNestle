import Foundation

/// The active boycott target. The app reads this from the dataset's target rows;
/// the default is only a v1 fallback if the dataset cannot be opened.
struct BoycottTarget: Equatable {
    let name: String

    static let defaultTarget = BoycottTarget(name: "Nestlé")
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

/// How a verdict was produced. Exact rows are strongest; prefix inference is a
/// conservative offline hedge from the optional prefixes table.
enum MatchBasis: Equatable {
    case exact
    case inferredFromPrefix
}

/// Result of resolving a barcode (or brand) to an owning company.
struct OwnershipResult: Identifiable, Equatable {
    let query: String          // the barcode or brand that was looked up
    let brandName: String?
    let parent: String?        // e.g. "Nestlé"
    let verdict: Verdict
    var productName: String? = nil   // from the online fallback (OFF); local has none
    var manufacturer: String? = nil  // brand owner / maker (esp. for non-target products)
    var matchBasis: MatchBasis = .exact
    var note: String? = nil
    var evidenceCount: Int? = nil
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

    var openFoodFactsContributionURL: URL? {
        guard verdict == .unknown,
              OpenFoodFactsContribution.looksLikeBarcode(query) else { return nil }
        return OpenFoodFactsContribution.addProductURL(barcode: query)
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
        if matchBasis == .inferredFromPrefix {
            out.append(("Basis", "Manufacturer prefix"))
        }
        if let evidenceCount, evidenceCount > 0 {
            let noun = evidenceCount == 1 ? "product" : "products"
            out.append(("Evidence", "\(evidenceCount) known \(noun)"))
        }
        if let note, !note.isEmpty { out.append(("Note", note)) }
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
