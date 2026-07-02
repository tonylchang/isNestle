import Foundation

/// Shared input rules for product barcodes that may leave the device.
///
/// Local lookup can still try any scanned string against the bundled database,
/// but network/contribution flows are limited to normal product barcode shapes.
enum BarcodeInput {
    private static let networkLengths: Set<Int> = [8, 12, 13, 14]

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func networkBarcode(_ value: String) -> String? {
        let code = trimmed(value)
        guard networkLengths.contains(code.count),
              isASCIIDigits(code) else { return nil }
        return code
    }

    static func exactLookupCandidates(for value: String) -> [String] {
        let code = trimmed(value)
        guard !code.isEmpty else { return [] }

        var candidates = [code]
        if isASCIIDigits(code) {
            if code.count == 12 {
                candidates.append("0\(code)")
            } else if code.count == 13, code.hasPrefix("0") {
                candidates.append(String(code.dropFirst()))
            }
        }
        return dedupe(candidates)
    }

    static func prefixLookupCandidates(for value: String) -> [String] {
        guard let gtin13 = gtin13Candidate(for: value),
              canInferFromPrefix(gtin13) else { return [] }
        return [gtin13]
    }

    private static func gtin13Candidate(for value: String) -> String? {
        let code = trimmed(value)
        guard isASCIIDigits(code) else { return nil }
        if code.count == 12 { return "0\(code)" }
        if code.count == 13 { return code }
        return nil
    }

    private static func canInferFromPrefix(_ gtin13: String) -> Bool {
        guard gtin13.count >= 6 else { return false }
        if gtin13.hasPrefix("02") || gtin13.hasPrefix("04") || gtin13.hasPrefix("05") {
            return false
        }
        if gtin13.hasPrefix("2") || gtin13.hasPrefix("978") || gtin13.hasPrefix("979") {
            return false
        }
        return true
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

/// Explicit-tap contribution flow for unknown products. The app never opens this
/// automatically; views only expose the URL as a user-initiated action.
enum OpenFoodFactsContribution {
    static func addProductURL(barcode: String) -> URL? {
        guard let code = BarcodeInput.networkBarcode(barcode) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "world.openfoodfacts.org"
        components.path = "/cgi/product.pl"
        components.queryItems = [
            URLQueryItem(name: "type", value: "add"),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url
    }

    static func looksLikeBarcode(_ value: String) -> Bool {
        BarcodeInput.networkBarcode(value) != nil
    }
}
