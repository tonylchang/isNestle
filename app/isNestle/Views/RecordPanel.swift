import SwiftUI

// MARK: - Theme 2: Record (typographic dossier, compact / no-scroll)

struct RecordPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    let target: BoycottTarget
    private var style: VerdictStyle { VerdictStyle(result.verdict, target: target) }
    private var determination: String {
        switch result.verdict {
        case .match:
            return result.matchBasis == .inferredFromPrefix ? "Likely \(target.name)" : target.name
        case .notTarget: return "Not \(target.name)"
        case .unknown: return "No \(target.name) record"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("OWNERSHIP RECORD")
            Text("GTIN \(result.query)")
                .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.top, 2)

            rule()
            eyebrow("DETERMINATION")
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(style.color).frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(determination).font(.system(.title3, design: .serif).weight(.semibold))
            }
            .padding(.top, 4)

            if !result.fields.isEmpty {
                rule()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.fields, id: \.label) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(f.label.uppercased())
                                .font(.system(.caption2, design: .monospaced)).tracking(1.5)
                                .foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            Text(f.value).font(.system(.subheadline, design: .serif).weight(.medium))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            rule()
            eyebrow("ASSESSMENT")
            Text(style.detail(result))
                .font(.system(.footnote, design: .serif)).padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
            OpenFoodFactsContributionLink(result: result)
                .padding(.top, 8)

            Spacer(minLength: 8)
            HStack {
                Text("Open Food Facts · Wikidata")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                if isLookingUp { onlineHint } else if result.fromOnline {
                    Text("online").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(14)
        .verdictAccessibility(style: style, result: result)
    }

    private func eyebrow(_ t: String) -> some View {
        Text(t).font(.system(.caption2, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
    }
    private func rule() -> some View {
        Rectangle().fill(Color(.separator)).frame(height: 1).padding(.vertical, 11)
    }
    private var onlineHint: some View {
        HStack(spacing: 5) { ProgressView().controlSize(.mini)
            Text("checking…").font(.system(.caption2, design: .monospaced)) }
            .foregroundStyle(.tertiary)
    }
}
