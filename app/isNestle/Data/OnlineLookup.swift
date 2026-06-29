import Foundation

/// Opt-in online fallback: resolve a barcode against the **free** Open Food Facts
/// API. Used only when the user enables online lookup AND the barcode isn't in the
/// bundled dataset. Sends only the barcode (+ the device IP, inherent to any
/// request) to OFF; nothing is stored and we run no server of our own.
enum OnlineLookup {
    struct Hit { let brandSlugs: [String]; let productName: String? }

    static func resolve(barcode: String) async -> Hit? {
        guard let encoded = barcode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string:
                "https://world.openfoodfacts.org/api/v2/product/\(encoded).json?fields=product_name,brands_tags")
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("isNestle/0.1 (iOS; https://github.com/tonylchang/isNestle)",
                     forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(OFFProductResponse.self, from: data)
            guard decoded.status == 1, let p = decoded.product else { return nil }
            let name = (p.product_name?.isEmpty == false) ? p.product_name : nil
            return Hit(brandSlugs: p.brands_tags ?? [], productName: name)
        } catch {
            return nil
        }
    }
}

private struct OFFProductResponse: Decodable {
    let status: Int?
    let product: OFFProduct?
}

private struct OFFProduct: Decodable {
    let product_name: String?
    let brands_tags: [String]?
}
