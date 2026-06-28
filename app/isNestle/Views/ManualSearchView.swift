import SwiftUI

/// Local brand-name search — the offline fallback when a barcode isn't scanned
/// or isn't in the dataset. Queries the bundled brands table only; nothing leaves
/// the device.
struct ManualSearchView: View {
    let db: BarcodeDatabase?
    @State private var query = ""
    @State private var hits: [BrandHit] = []

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a brand name to check whether it’s owned by \(Target.name).")
                    .foregroundStyle(.secondary)
            } else if hits.isEmpty {
                Text("No matching brand in the database. That doesn’t prove it isn’t \(Target.name) — only that it isn’t catalogued here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hits) { hit in
                    HStack(spacing: 12) {
                        Image(systemName: hit.isTarget ? "xmark.octagon.fill" : "checkmark.seal.fill")
                            .foregroundStyle(hit.isTarget ? .red : .green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.brandName).font(.headline)
                            Text(hit.isTarget ? "Made by \(hit.parent)" : "Not \(Target.name)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(hit.brandName), \(hit.isTarget ? "made by \(hit.parent)" : "not \(Target.name)")")
                }
            }
        }
        .navigationTitle("Brand search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Brand name")
        .onChange(of: query) { _ in
            hits = db?.searchBrands(query: query) ?? []
        }
    }
}
