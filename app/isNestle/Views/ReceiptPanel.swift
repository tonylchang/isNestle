import SwiftUI

// MARK: - Theme 3: Receipt (monospace checkout slip, torn edge)

struct ReceiptPanel: View {
    let result: OwnershipResult
    let isLookingUp: Bool
    let target: BoycottTarget
    private var style: VerdictStyle { VerdictStyle(result.verdict, target: target) }
    private let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    private let inkColor = Color(red: 0.16, green: 0.15, blue: 0.14)

    var body: some View {
        VStack(spacing: 9) {
            Text("isNESTLE  MARKET")
                .font(.system(.subheadline, design: .monospaced)).fontWeight(.bold)
            Text("CHECKOUT · OPEN FOOD FACTS")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
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
                Text(style.shortWord(result).uppercased())
                    .font(.system(.subheadline, design: .monospaced)).fontWeight(.heavy)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(style.color)

            Text(style.detail(result))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            OpenFoodFactsContributionLink(result: result, foreground: inkColor.opacity(0.75))

            Spacer(minLength: 4)
            fakeBarcode()
            Text(result.query)
                .font(.system(.caption2, design: .monospaced)).tracking(2)
            Text(isLookingUp ? "CHECKING ONLINE…" : (result.fromOnline ? "VIA ONLINE LOOKUP · ODbL" : "ODbL · CC0"))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
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
        .verdictAccessibility(style: style, result: result)
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

private struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p
    }
}
