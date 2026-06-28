import SwiftUI

struct AboutView: View {
    let db: BarcodeDatabase?

    var body: some View {
        let counts = db?.counts() ?? (brands: 0, barcodes: 0)
        List {
            Section("isNestle") {
                Text("Scan a barcode to see whether a product is made by \(Target.name) or one of its subsidiaries — fully offline. Nothing you scan or search ever leaves your device.")
            }
            Section("Data") {
                LabeledContent("Brands", value: "\(counts.brands)")
                LabeledContent("Barcodes", value: "\(counts.barcodes)")
                Text("Product data from Open Food Facts (ODbL). Brand ownership from Wikidata (CC0) and Wikipedia.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Please note") {
                Text("Ownership data may be incomplete or out of date, and some brands are made under license by other companies in certain regions. Verdicts are a guide, not a legal statement.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
