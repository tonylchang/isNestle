import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private static let privacyURL = URL(string: "https://tonylchang.github.io/isNestle/privacy.html")!

    var body: some View {
        let counts = model.db?.counts() ?? (brands: 0, barcodes: 0)
        Form {
            Section {
                Picker("Verdict theme", selection: $model.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Verdict theme")
            } footer: {
                Text(model.theme.blurb)
            }

            Section("Online lookup") {
                Toggle("Check unknown barcodes online", isOn: $model.onlineEnabled)
                Text("Off by default. When on, a barcode that isn’t in the offline database is sent to Open Food Facts to identify the product and check its brand against the target list. Only the barcode (and your IP) is sent; nothing is stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Dataset version", value: model.datasetVersion)
                LabeledContent("Brands", value: "\(counts.brands)")
                LabeledContent("Barcodes", value: "\(counts.barcodes)")
                Button {
                    Task { await model.checkForDatasetUpdate(force: true) }
                } label: {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        updateStatus
                    }
                }
                .disabled(model.updateState == .checking)
                Link("Privacy policy", destination: Self.privacyURL)
                Text("The dataset updates itself from a public file — nothing about your scans is sent. Product data: Open Food Facts (ODbL). Brand ownership: Wikidata (CC0), Wikipedia.")
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

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updateState {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
        case .upToDate:
            Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case .updated(let v):
            Label("Updated to \(v)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .failed(let why):
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
    }
}
