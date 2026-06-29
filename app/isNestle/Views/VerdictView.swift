import SwiftUI

/// Verdict presentation entry point. M1 ships the **Minimal** theme; this is the
/// seam where the **Informational** theme (and others) plug in for M2 — see UI.md.
struct VerdictView: View {
    let result: OwnershipResult
    let onDismiss: () -> Void

    var body: some View {
        MinimalVerdictView(result: result, onDismiss: onDismiss)
    }
}

/// Bold & instant: full-screen color flood + icon + a word or two. Color is
/// always reinforced by an SF Symbol and text, so the verdict is never conveyed
/// by color alone (accessibility requirement, UI.md).
struct MinimalVerdictView: View {
    let result: OwnershipResult
    let onDismiss: () -> Void

    private var style: VerdictStyle { VerdictStyle(result.verdict) }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: style.symbol)
                .font(.system(size: 92, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text(style.headline)
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !result.chain.isEmpty {
                Text(result.chain.joined(separator: "  →  "))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
            }
            Text(style.detail(result))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button(action: onDismiss) {
                Text("Scan another")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(style.color)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Visual + textual mapping for each verdict. Red = a boycott match (avoid),
/// green = clear to buy, gray = unknown.
private struct VerdictStyle {
    let verdict: Verdict
    init(_ v: Verdict) { verdict = v }

    var color: Color {
        switch verdict {
        case .match:     return Color(red: 0.78, green: 0.13, blue: 0.13)
        case .notTarget: return Color(red: 0.13, green: 0.50, blue: 0.24)
        case .unknown:   return Color(red: 0.16, green: 0.52, blue: 0.30)
        }
    }

    var symbol: String {
        switch verdict {
        case .match:     return "xmark.octagon.fill"
        case .notTarget: return "checkmark.seal.fill"
        case .unknown:   return "checkmark.seal.fill"
        }
    }

    var headline: String {
        switch verdict {
        case .match:     return Target.name.uppercased()
        case .notTarget: return "NOT \(Target.name.uppercased())"
        case .unknown:   return "NO \(Target.name.uppercased()) MATCH"
        }
    }

    func detail(_ r: OwnershipResult) -> String {
        switch r.verdict {
        case .match:
            let brand = r.brandName.map { " (brand: \($0))" } ?? ""
            return "This product is made by \(Target.name)\(brand)."
        case .notTarget:
            let brand = r.brandName.map { " It’s \($0)." } ?? ""
            return "Not made by \(Target.name).\(brand)"
        case .unknown:
            return "Not found in the \(Target.name) database, so it’s most likely fine. Coverage isn’t exhaustive, though — this isn’t a guarantee. You can double-check with a brand search."
        }
    }

    func accessibilityLabel(_ r: OwnershipResult) -> String {
        var parts = [headline + "."]
        if !r.chain.isEmpty { parts.append(r.chain.joined(separator: ", owned by ") + ".") }
        parts.append(detail(r))
        return parts.joined(separator: " ")
    }
}

// MARK: - Inline display panel (camera-rectangle layout)

/// Fills the area below the viewfinder: the latest verdict inline, or idle
/// instructions when nothing has been scanned yet.
struct ResultPanel: View {
    let result: OwnershipResult?
    let isLookingUp: Bool

    var body: some View {
        if let result {
            VerdictPanel(result: result, isLookingUp: isLookingUp)
        } else {
            IdlePanel()
        }
    }
}

private struct IdlePanel: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "viewfinder")
                .font(.system(size: 44)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Center a barcode in the frame")
                .font(.headline)
            Text("You’ll see instantly whether it’s made by \(Target.name).")
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

/// Bold, color-flooded inline verdict — keeps the Minimal theme's instant read,
/// now in the display area beneath the live camera (color always paired with an
/// icon + text, never color alone).
private struct VerdictPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    private var style: VerdictStyle { VerdictStyle(result.verdict) }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 8)
            Image(systemName: style.symbol)
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text(style.headline)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let name = result.productName {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if !result.chain.isEmpty {
                Text(result.chain.joined(separator: "  →  "))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
            }
            Text(style.detail(result))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if result.fromOnline {
                Label("via online lookup", systemImage: "wifi")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 8)
            if isLookingUp {
                HStack(spacing: 6) {
                    ProgressView().tint(.white)
                    Text("Checking online…")
                }
                .font(.caption).foregroundStyle(.white.opacity(0.9))
            } else {
                Text("Point at another barcode to scan again")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
    }
}
