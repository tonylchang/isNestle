import SwiftUI

// MARK: - Theme 4: Tag (price tag, verdict as the price)

struct TagPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    let target: BoycottTarget
    private var style: VerdictStyle { VerdictStyle(result.verdict, target: target) }
    private let kraft = Color(red: 0.89, green: 0.85, blue: 0.76)
    private let card = Color(red: 0.99, green: 0.98, blue: 0.96)
    private let ink = Color(red: 0.18, green: 0.16, blue: 0.13)

    var body: some View {
        ZStack {
            kraft.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    holePunch
                    Spacer()
                    Text(result.fromOnline ? "ONLINE" : "SHELF TAG")
                        .font(.system(.caption2, design: .rounded)).fontWeight(.bold)
                        .tracking(1.5).foregroundStyle(ink.opacity(0.45))
                }

                Spacer(minLength: 6)

                Text((result.displayName ?? "Unlisted item").uppercased())
                    .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                    .foregroundStyle(ink.opacity(0.6)).tracking(0.5)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The "price" = the verdict.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: style.symbol)
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(style.color)
                        .accessibilityHidden(true)
                    Text(style.shortWord(result))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(style.color)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)

                if let maker = makerLine {
                    Text(maker).font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(ink.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 2)
                }
                if let support = supportLine {
                    Text(support).font(.system(.caption, design: .rounded))
                        .foregroundStyle(ink.opacity(0.56))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2).minimumScaleFactor(0.75).padding(.top, 4)
                }
                OpenFoodFactsContributionLink(result: result, foreground: ink.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, result.openFoodFactsContributionURL == nil ? 0 : 6)

                Spacer(minLength: 6)

                HStack {
                    Text("GTIN \(result.query)")
                        .font(.system(.caption2, design: .rounded)).foregroundStyle(ink.opacity(0.5))
                    Spacer()
                    if isLookingUp {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .padding(22)
            .background(card)
            .clipShape(TagShape())
            .overlay(TagShape().stroke(ink.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
    }

    private var makerLine: String? {
        switch result.verdict {
        case .match:
            return result.matchBasis == .inferredFromPrefix
                ? "Manufacturer code: \(target.name)"
                : "Owned by \(target.name)"
        case .notTarget: return result.manufacturer.map { "Made by \($0)" }
        case .unknown: return nil
        }
    }
    private var supportLine: String? {
        if result.verdict == .match, result.matchBasis == .inferredFromPrefix,
           let evidence = result.evidenceCount, evidence > 0 {
            return "\(evidence) known \(evidence == 1 ? "product" : "products") under this prefix"
        }
        return result.note
    }
    private var holePunch: some View {
        Circle().fill(kraft).frame(width: 22, height: 22)
            .overlay(Circle().stroke(ink.opacity(0.18), lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// Price-tag outline: rounded rect with the top-left corner sliced off.
private struct TagShape: Shape {
    func path(in r: CGRect) -> Path {
        let cut = 30.0, rad = 14.0
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(center: CGPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
        p.closeSubpath()
        return p
    }
}
