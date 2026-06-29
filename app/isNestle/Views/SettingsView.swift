import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private static let privacyURL = URL(string: "https://tonylchang.github.io/isNestle/")!

    var body: some View {
        let counts = model.db?.counts() ?? (brands: 0, barcodes: 0)
        Form {
            Section("Appearance") {
                Picker("Verdict theme", selection: $model.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.theme.blurb)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Online lookup") {
                Toggle("Check unknown barcodes online", isOn: $model.onlineEnabled)
                Text("Off by default. When on, a barcode that isn’t in the offline database is sent to Open Food Facts to identify it — giving a confident result and the product name. Only the barcode (and your IP) is sent; nothing is stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Brands", value: "\(counts.brands)")
                LabeledContent("Barcodes", value: "\(counts.barcodes)")
                Link("Privacy policy", destination: Self.privacyURL)
                Text("Product data: Open Food Facts (ODbL). Brand ownership: Wikidata (CC0), Wikipedia.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Ownership data may be incomplete or out of date, and some brands are made under license by other companies in certain regions. Verdicts are a guide, not a legal statement.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
