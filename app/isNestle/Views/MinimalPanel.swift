import SwiftUI

// MARK: - Theme 1: Minimal (bold color flood)

struct MinimalPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    let target: BoycottTarget
    private var style: VerdictStyle { VerdictStyle(result.verdict, target: target) }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 8)
            Image(systemName: style.symbol)
                .font(.system(size: 50, weight: .bold)).foregroundStyle(.white)
                .accessibilityHidden(true)
            Text(style.headline(result))
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white).multilineTextAlignment(.center)
            if let name = result.productName {
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            }
            if !result.chain.isEmpty {
                Text(result.chain.joined(separator: "  →  "))
                    .font(.headline).foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
            }
            Text(style.detail(result))
                .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center).padding(.horizontal)
            if result.fromOnline {
                Label("via online lookup", systemImage: "wifi")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            OpenFoodFactsContributionLink(result: result, foreground: .white.opacity(0.9))
            Spacer(minLength: 8)
            footnote(isLookingUp: isLookingUp, color: .white.opacity(0.85))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
    }

    private func footnote(isLookingUp: Bool, color: Color) -> some View {
        Group {
            if isLookingUp {
                HStack(spacing: 6) { ProgressView().tint(color); Text("Checking online…") }
            } else {
                Text("Point at another barcode to scan again")
            }
        }
        .font(.caption).foregroundStyle(color)
    }
}
