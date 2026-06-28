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
        case .unknown:   return Color(red: 0.36, green: 0.38, blue: 0.42)
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
        case .match:     return Target.name.uppercased()
        case .notTarget: return "NOT \(Target.name.uppercased())"
        case .unknown:   return "UNKNOWN"
        }
    }

    func detail(_ r: OwnershipResult) -> String {
        switch r.verdict {
        case .match:
            let brand = r.brandName.map { " (brand: \($0))" } ?? ""
            return "This product is made by \(Target.name)\(brand)."
        case .notTarget:
            return "This product is not made by \(Target.name)."
        case .unknown:
            return "This barcode isn’t in the offline database. It may be a \(Target.name) product that isn’t catalogued yet — try a brand search."
        }
    }

    func accessibilityLabel(_ r: OwnershipResult) -> String {
        var parts = [headline + "."]
        if !r.chain.isEmpty { parts.append(r.chain.joined(separator: ", owned by ") + ".") }
        parts.append(detail(r))
        return parts.joined(separator: " ")
    }
}
