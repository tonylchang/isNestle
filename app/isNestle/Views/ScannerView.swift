import SwiftUI
import VisionKit

/// Live barcode scanning when supported (real devices); a manual-entry fallback
/// otherwise (e.g. the iOS Simulator has no camera).
struct BarcodeScannerView: View {
    let isScanning: Bool
    let onScan: (String) -> Void

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        if canScan {
            ZStack(alignment: .bottom) {
                DataScannerRepresentable(isScanning: isScanning, onScan: onScan)
                Text("Point the camera at a product barcode")
                    .font(.callout).bold()
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 28)
                    .accessibilityHidden(true)
            }
        } else {
            ScannerUnavailableView(onSubmit: onScan)
        }
    }
}

private struct ScannerUnavailableView: View {
    let onSubmit: (String) -> Void
    @State private var code = ""

    private var trimmed: String { code.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Live scanning isn’t available here")
                .font(.headline)
            Text("Run on a real iPhone to scan with the camera. You can still enter a barcode manually:")
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
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let isScanning: Bool
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if isScanning {
            context.coordinator.didScan = false
            try? vc.startScanning()
        } else {
            vc.stopScanning()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        var didScan = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !didScan else { return }
            for case let .barcode(barcode) in items {
                if let payload = barcode.payloadStringValue, !payload.isEmpty {
                    didScan = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}
