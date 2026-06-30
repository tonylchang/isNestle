import SwiftUI

// MARK: - Shared verdict styling

/// Visual + textual mapping for each verdict. Red = a boycott match (avoid),
/// green = confirmed clear, gray = unknown/no match. Color is always reinforced
/// by an SF Symbol + text (never color alone — accessibility, UI.md).
struct VerdictStyle {
    let verdict: Verdict
    init(_ v: Verdict) { verdict = v }

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
        case .match:     return Target.name.uppercased()
        case .notTarget: return "NOT \(Target.name.uppercased())"
        case .unknown:   return "NO \(Target.name.uppercased()) MATCH"
        }
    }
    /// Short word(s) for tight spots (receipt/tag).
    var shortWord: String {
        switch verdict {
        case .match:     return Target.name
        case .notTarget: return "Not \(Target.name)"
        case .unknown:   return "No match"
        }
    }
    func detail(_ r: OwnershipResult) -> String {
        switch r.verdict {
        case .match:
            let brand = r.brandName.map { " (brand: \($0))" } ?? ""
            return "This product is made by \(Target.name)\(brand)."
        case .notTarget:
            let maker = r.manufacturer.map { " Made by \($0)." } ?? ""
            return "Not made by \(Target.name).\(maker)"
        case .unknown:
            if r.fromOnline, r.displayName != nil {
                return "Product identified online, but no \(Target.name) ownership match was found in the current database. Coverage isn’t exhaustive."
            }
            return "Not found in the \(Target.name) database. Coverage isn’t exhaustive, so this isn’t proof either way."
        }
    }
    func accessibilityLabel(_ r: OwnershipResult) -> String {
        var parts = [headline + "."]
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

    var body: some View {
        if let result {
            switch theme {
            case .minimal:       MinimalPanel(result: result, isLookingUp: isLookingUp)
            case .informational: RecordPanel(result: result, isLookingUp: isLookingUp)
            case .receipt:       ReceiptPanel(result: result, isLookingUp: isLookingUp)
            case .tag:           TagPanel(result: result, isLookingUp: isLookingUp)
            }
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
            Text("Center a barcode in the frame").font(.headline)
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

// MARK: - Theme 1: Minimal (bold color flood)

private struct MinimalPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    private var style: VerdictStyle { VerdictStyle(result.verdict) }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 8)
            Image(systemName: style.symbol)
                .font(.system(size: 50, weight: .bold)).foregroundStyle(.white)
                .accessibilityHidden(true)
            Text(style.headline)
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
            Spacer(minLength: 8)
            footnote(isLookingUp: isLookingUp, color: .white.opacity(0.85))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
    }
}

// MARK: - Theme 2: Record (typographic dossier, compact / no-scroll)

private struct RecordPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    private var style: VerdictStyle { VerdictStyle(result.verdict) }
    private var determination: String {
        switch result.verdict {
        case .match: return Target.name
        case .notTarget: return "Not \(Target.name)"
        case .unknown: return "No \(Target.name) record"
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
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

// MARK: - Theme 3: Receipt (monospace checkout slip, torn edge)

private struct ReceiptPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    private var style: VerdictStyle { VerdictStyle(result.verdict) }
    private let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    private let inkColor = Color(red: 0.16, green: 0.15, blue: 0.14)

    var body: some View {
        VStack(spacing: 9) {
            Text("isNESTLE  MARKET")
                .font(.system(.subheadline, design: .monospaced)).fontWeight(.bold)
            Text("CHECKOUT · OPEN FOOD FACTS")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            dashes()

            ForEach(result.fields, id: \.label) { f in
                HStack(spacing: 8) {
                    Text(f.label.uppercased()).font(.system(.caption, design: .monospaced))
                    Spacer(minLength: 6)
                    Text(f.value).font(.system(.caption, design: .monospaced)).fontWeight(.semibold)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if result.fields.isEmpty {
                HStack { Text("ITEM").font(.system(.caption, design: .monospaced))
                    Spacer(); Text("UNLISTED").font(.system(.caption, design: .monospaced)) }
            }
            dashes()

            // Verdict line — inverted bar, mono, icon + word.
            HStack(spacing: 8) {
                Image(systemName: style.symbol).font(.caption)
                Text("VERDICT").font(.system(.caption, design: .monospaced))
                Spacer()
                Text(style.shortWord.uppercased())
                    .font(.system(.subheadline, design: .monospaced)).fontWeight(.heavy)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(style.color)

            Text(style.detail(result))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)
            fakeBarcode()
            Text(result.query)
                .font(.system(size: 11, design: .monospaced)).tracking(2)
            Text(isLookingUp ? "CHECKING ONLINE…" : (result.fromOnline ? "VIA ONLINE LOOKUP · ODbL" : "ODbL · CC0"))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(inkColor)
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(paper)
        .clipShape(ReceiptShape())
        .padding(.horizontal, 26).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel(result))
    }

    private func dashes() -> some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1).foregroundStyle(.secondary.opacity(0.6))
    }
    private func fakeBarcode() -> some View {
        let widths: [CGFloat] = [1, 2, 3, 1, 2, 1, 3, 2]
        return HStack(spacing: 2) {
            ForEach(0..<34, id: \.self) { i in
                Rectangle().frame(width: widths[(i * 7 + 3) % widths.count], height: 26)
            }
        }
        .foregroundStyle(inkColor)
    }
}

/// Receipt outline: square top, zig-zag torn bottom edge.
private struct ReceiptShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let teeth = 12.0, tw = 14.0
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - teeth))
        var x = r.maxX
        var up = true
        while x > r.minX {
            x -= tw
            p.addLine(to: CGPoint(x: max(x, r.minX), y: up ? r.maxY : r.maxY - teeth))
            up.toggle()
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        return p
    }
}

// MARK: - Theme 4: Tag (price tag, verdict as the price)

private struct TagPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    private var style: VerdictStyle { VerdictStyle(result.verdict) }
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
                    Text(style.shortWord)
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
        case .match: return "Owned by \(Target.name)"
        case .notTarget: return result.manufacturer.map { "Made by \($0)" }
        case .unknown: return nil
        }
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

// MARK: - Helpers

private struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p
    }
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
