import SwiftUI

/// Local brand-name search — the offline fallback when a barcode isn't scanned
/// or isn't in the dataset. Queries the bundled brands table only; nothing leaves
/// the device.
struct ManualSearchView: View {
    let db: BarcodeDatabase?
    let target: BoycottTarget
    @State private var query = ""
    @State private var hits: [BrandHit] = []

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type a brand name to check whether it’s owned by \(target.name).")
                    .foregroundStyle(.secondary)
            } else if hits.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No matching brand in the database. That doesn’t prove it isn’t \(target.name) — only that it isn’t catalogued here.")
                        .foregroundStyle(.secondary)
                    if let url = contributionURL {
                        Link(destination: url) {
                            Label("Not found? Add it to Open Food Facts", systemImage: "square.and.pencil")
                        }
                        .font(.subheadline.weight(.medium))
                        Text("This opens Open Food Facts. The barcode is sent only after you tap.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(hits) { hit in
                    HStack(spacing: 12) {
                        Image(systemName: hit.isTarget ? "xmark.octagon.fill" : "checkmark.seal.fill")
                            .foregroundStyle(hit.isTarget ? .red : .green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.brandName).font(.headline)
                            Text(hit.isTarget ? "Made by \(hit.parent)" : "Not \(target.name)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(hit.brandName), \(hit.isTarget ? "made by \(hit.parent)" : "not \(target.name)")")
                }
            }
        }
        .navigationTitle("Brand search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: searchText, prompt: "Brand name")
    }

    private var searchText: Binding<String> {
        Binding(
            get: { query },
            set: { newQuery in
                query = newQuery
                hits = db?.searchBrands(query: newQuery) ?? []
            }
        )
    }

    private var contributionURL: URL? {
        guard OpenFoodFactsContribution.looksLikeBarcode(query) else { return nil }
        return OpenFoodFactsContribution.addProductURL(barcode: query)
    }
}
