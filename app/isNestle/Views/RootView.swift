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
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        AboutView(db: model.db)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About and data sources")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ManualSearchView(db: model.db)
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
                    .frame(height: geo.size.height * 0.46)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
                    .padding([.horizontal, .top])

                // The rest of the screen: live result / instructions display.
                ResultPanel(result: model.result, onClear: model.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemBackground))
    }
}
