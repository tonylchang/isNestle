import AppIntents
import Foundation

/// App Intents: verdicts without opening the app (Shortcuts, Spotlight, Siri).
///
/// Privacy: intents are **offline-only** — they query the bundled/self-updated
/// SQLite via `DatasetStore` and never use the online fallback, regardless of
/// the in-app online-lookup toggle (FEATURES.md).

/// One-line spoken/displayed verdict summaries. Pure functions so the intents
/// stay thin wrappers and the wording is unit-testable.
enum IntentVerdict {
    static func summary(for result: OwnershipResult, target: BoycottTarget) -> String {
        let style = VerdictStyle(result.verdict, target: target)
        var lead = style.shortWord(result)
        if let name = result.displayName, result.verdict != .unknown {
            lead = "\(name): \(lead)"
        }
        return "\(lead). \(style.detail(result))"
    }

    static func summary(for hit: BrandHit?, query: String, target: BoycottTarget) -> String {
        guard let hit else {
            return "No \(target.name) match for “\(query)”. Coverage isn’t exhaustive, "
                + "so this isn’t proof either way."
        }
        return hit.isTarget
            ? "\(hit.brandName) is made by \(hit.parent)."
            : "\(hit.brandName) is not \(target.name)."
    }
}

struct CheckBarcodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Check a Barcode"
    static let description = IntentDescription(
        "Checks a product barcode against the offline dataset. Runs fully on-device; nothing leaves your phone.")

    @Parameter(title: "Barcode")
    var barcode: String

    static var parameterSummary: some ParameterSummary {
        Summary("Check barcode \(\.$barcode)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let db = DatasetStore.openActiveDatabase() else {
            return .result(dialog: "The offline database couldn’t be opened.")
        }
        let result = db.lookup(barcode: BarcodeInput.trimmed(barcode))
        let summary = IntentVerdict.summary(for: result, target: db.activeTarget())
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct CheckBrandIntent: AppIntent {
    static let title: LocalizedStringResource = "Check a Brand"
    static let description = IntentDescription(
        "Checks a brand name against the offline dataset. Runs fully on-device; nothing leaves your phone.")

    @Parameter(title: "Brand name")
    var brand: String

    static var parameterSummary: some ParameterSummary {
        Summary("Check brand \(\.$brand)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let db = DatasetStore.openActiveDatabase() else {
            return .result(dialog: "The offline database couldn’t be opened.")
        }
        let query = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let hit = db.searchBrands(query: query, limit: 1).first
        let summary = IntentVerdict.summary(for: hit, query: query, target: db.activeTarget())
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct IsNestleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckBarcodeIntent(),
            phrases: [
                "Check a barcode with \(.applicationName)",
                "Check this barcode in \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: CheckBrandIntent(),
            phrases: [
                "Check a brand with \(.applicationName)",
                "Is this brand in \(.applicationName)",
            ]
        )
    }
}
