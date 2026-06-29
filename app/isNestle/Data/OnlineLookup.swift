import Foundation

/// Opt-in online fallback: resolve a barcode against the **free** Open Food Facts
/// API. Used only when the user enables online lookup AND the barcode isn't in the
/// bundled dataset. Sends only the barcode (+ the device IP, inherent to any
/// request) to OFF; nothing is stored and we run no server of our own.
enum OnlineLookup {
    struct Hit {
        let brandSlugs: [String]
        let productName: String?
        let brandsDisplay: String?   // human "brands" string (e.g. "Coca-Cola")
        let owner: String?           // brand_owner / manufacturer, when OFF has it
    }

    static func resolve(barcode: String) async -> Hit? {
        guard let encoded = barcode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string:
                "https://world.openfoodfacts.org/api/v2/product/\(encoded).json?fields=product_name,brands,brands_tags,brand_owner")
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
            func clean(_ s: String?) -> String? {
                guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return s
            }
            return Hit(brandSlugs: p.brands_tags ?? [],
                       productName: clean(p.product_name),
                       brandsDisplay: clean(p.brands),
                       owner: clean(p.brand_owner))
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
    let brands: String?
    let brands_tags: [String]?
    let brand_owner: String?
}
