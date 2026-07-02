import SwiftUI

// MARK: - Shared verdict styling

/// Visual + textual mapping for each verdict. Red = a boycott match (avoid),
/// green = confirmed clear, gray = unknown/no match. Color is always reinforced
/// by an SF Symbol + text (never color alone — accessibility, UI.md).
struct VerdictStyle {
    let verdict: Verdict
    let target: BoycottTarget

    init(_ v: Verdict, target: BoycottTarget) {
        verdict = v
        self.target = target
    }

    var color: Color {
        switch verdict {
        case .match:     return Color(red: 0.78, green: 0.13, blue: 0.13)
        case .notTarget: return Color(red: 0.13, green: 0.50, blue: 0.24)
        case .unknown:   return Color(red: 0.34, green: 0.36, blue: 0.39)
        }
    }
    var symbol: String {
        switch verdict {
        case .match:     return "xmark.octagon.fill"
        case .notTarget: return "checkmark.seal.fill"
        case .unknown:   return "questionmark.circle.fill"
        }
    }
    var headline: String {
        switch verdict {
        case .match:     return target.name.uppercased()
        case .notTarget: return "NOT \(target.name.uppercased())"
        case .unknown:   return "NO \(target.name.uppercased()) MATCH"
        }
    }
    func headline(_ r: OwnershipResult) -> String {
        if r.verdict == .match, r.matchBasis == .inferredFromPrefix {
            return "LIKELY \(target.name.uppercased())"
        }
        return headline
    }
    /// Short word(s) for tight spots (receipt/tag).
    var shortWord: String {
        switch verdict {
        case .match:     return target.name
        case .notTarget: return "Not \(target.name)"
        case .unknown:   return "No match"
        }
    }
    func shortWord(_ r: OwnershipResult) -> String {
        if r.verdict == .match, r.matchBasis == .inferredFromPrefix {
            return "Likely \(target.name)"
        }
        return shortWord
    }
    func detail(_ r: OwnershipResult) -> String {
        switch r.verdict {
        case .match:
            if r.matchBasis == .inferredFromPrefix {
                let evidence = r.evidenceCount.map { "; \($0) known \($0 == 1 ? "product" : "products")" } ?? ""
                return "Likely \(target.name) - this barcode's manufacturer code belongs to \(target.name)\(evidence)."
            }
            let brand = r.brandName.map { " (brand: \($0))" } ?? ""
            return "This product is made by \(target.name)\(brand)."
        case .notTarget:
            let maker = r.manufacturer.map { " Made by \($0)." } ?? ""
            let note = r.note.map { " \($0)" } ?? ""
            return "Not made by \(target.name).\(maker)\(note)"
        case .unknown:
            if let note = r.note {
                return "\(note) Coverage isn’t exhaustive, so this isn’t proof either way."
            }
            if r.fromOnline, r.displayName != nil {
                return "Product identified online, but no \(target.name) ownership match was found in the current database. Coverage isn’t exhaustive."
            }
            return "Not found in the \(target.name) database. Coverage isn’t exhaustive, so this isn’t proof either way."
        }
    }
    func accessibilityLabel(_ r: OwnershipResult) -> String {
        var parts = [headline(r) + "."]
        for f in r.fields { parts.append("\(f.label): \(f.value).") }
        parts.append(detail(r))
        return parts.joined(separator: " ")
    }
}

// MARK: - Inline display panel (router)

/// Fills the area below the viewfinder: the latest verdict in the chosen theme,
/// or idle instructions when nothing has been scanned yet.
struct ResultPanel: View {
    let result: OwnershipResult?
    let isLookingUp: Bool
    let theme: AppTheme
    let target: BoycottTarget

    var body: some View {
        if let result {
            switch theme {
            case .minimal:
                MinimalPanel(result: result, isLookingUp: isLookingUp, target: target)
            case .informational:
                RecordPanel(result: result, isLookingUp: isLookingUp, target: target)
            case .receipt:
                ReceiptPanel(result: result, isLookingUp: isLookingUp, target: target)
            case .tag:
                TagPanel(result: result, isLookingUp: isLookingUp, target: target)
            }
        } else {
            IdlePanel(target: target)
        }
    }
}

struct OpenFoodFactsContributionLink: View {
    let result: OwnershipResult
    var foreground: Color = .accentColor

    var body: some View {
        if let url = result.openFoodFactsContributionURL {
            Link(destination: url) {
                Label("Not found? Add it to Open Food Facts", systemImage: "square.and.pencil")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(foreground)
            .accessibilityHint("Opens Open Food Facts. The barcode is sent only after you tap.")
        }
    }
}

private struct IdlePanel: View {
    let target: BoycottTarget

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "viewfinder")
                .font(.system(size: 44)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Center a barcode in the frame").font(.headline)
            Text("You’ll see instantly whether it’s made by \(target.name).")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Text("Product data: Open Food Facts (ODbL)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
