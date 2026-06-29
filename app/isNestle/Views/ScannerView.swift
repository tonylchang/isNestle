import SwiftUI
import VisionKit

/// Inset fractions of the camera box that define the active scan rectangle.
/// Shared so the visual viewfinder and the scanner's regionOfInterest line up.
private enum ROI {
    static let x = 0.08, y = 0.15, w = 0.84, h = 0.70
    static func rect(in size: CGSize) -> CGRect {
        CGRect(x: size.width * x, y: size.height * y,
               width: size.width * w, height: size.height * h)
    }
}

/// Live barcode scanning, restricted to a viewfinder rectangle. Falls back to
/// manual entry where the camera is unavailable (e.g. the iOS Simulator).
struct BarcodeScannerView: View {
    let onScan: (String) -> Void

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        if canScan {
            ZStack {
                DataScannerRepresentable(onScan: onScan)
                ViewfinderOverlay()
            }
        } else {
            ScannerUnavailableView(onSubmit: onScan)
        }
    }
}

/// Dims the camera outside the scan rectangle and draws the viewfinder frame.
private struct ViewfinderOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let r = ROI.rect(in: geo.size)
            ZStack {
                Color.black.opacity(0.45)
                    .mask {
                        ZStack {
                            Rectangle()
                            RoundedRectangle(cornerRadius: 14)
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                                .blendMode(.destinationOut)
                        }
                    }
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct ScannerUnavailableView: View {
    let onSubmit: (String) -> Void
    @State private var code = ""
    private var trimmed: String { code.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No camera here — enter a barcode")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                TextField("Barcode digits", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Barcode digits")
                Button("Check") { if !trimmed.isEmpty { onSubmit(trimmed) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        // Restrict detection to the viewfinder rectangle (matches ViewfinderOverlay).
        let b = vc.view.bounds
        if b.width > 0, b.height > 0 {
            vc.regionOfInterest = ROI.rect(in: b.size)
        }
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var lastCode: String?
        private var lastTime = Date.distantPast

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        /// Continuous scanning with a small debounce so the same barcode held in
        /// view doesn't re-fire repeatedly; a *different* barcode updates instantly.
        private func handle(_ items: [RecognizedItem]) {
            for case let .barcode(barcode) in items {
                guard let payload = barcode.payloadStringValue, !payload.isEmpty else { continue }
                let now = Date()
                if payload == lastCode, now.timeIntervalSince(lastTime) < 2 { return }
                lastCode = payload
                lastTime = now
                onScan(payload)
                return
            }
        }
    }
}
