import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.db == nil {
                    ContentUnavailableState()
                } else {
                    ScannerScreen(model: model)
                }
            }
            .navigationTitle("isNestle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        ManualSearchView(db: model.db, target: model.target)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search by brand name")
                }
            }
        }
    }
}

/// Shown only if the bundled database failed to load (should not happen in a
/// correctly built app).
private struct ContentUnavailableState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Couldn’t load the offline database.")
                .font(.headline)
        }
        .padding()
    }
}

struct ScannerScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Camera viewfinder — the only region that scans.
                BarcodeScannerView { code in model.handleScanned(code) }
                    .frame(height: geo.size.height * 0.40)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
                    .padding([.horizontal, .top])

                // The rest of the screen: live result / instructions display.
                ResultPanel(result: model.result, isLookingUp: model.isLookingUp,
                            theme: model.theme, target: model.target)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Persistent opt-in control for the online fallback.
                OnlineLookupBar(enabled: $model.onlineEnabled)
            }
        }
        .background(Color(.systemBackground))
    }
}

/// The "spot" for the opt-in online lookup — off by default, with a privacy note.
struct OnlineLookupBar: View {
    @Binding var enabled: Bool
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: enabled ? "wifi" : "wifi.slash")
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Online lookup").font(.subheadline.weight(.medium))
                Text(enabled ? "Checks unknown barcodes online" : "Off — fully private")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("About online lookup")
            Spacer(minLength: 4)
            Toggle("Online lookup", isOn: $enabled).labelsHidden()
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
        .alert("Online lookup", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Off by default. When on, a barcode that isn’t in the offline database is sent to Open Food Facts to identify the product and check its brand against the target list. Unknown results may also show an add-product link; that opens Open Food Facts only when you tap it. Only the barcode (and your IP) is sent; nothing is stored.")
        }
    }
}
