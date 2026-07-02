import Foundation
import SQLite3

/// Read-only access to the bundled isNestle dataset (brands + barcodes).
///
/// Dependency-free: uses the system SQLite via the `SQLite3` module — no SPM
/// packages (see STACK.md). The bundled `isnestle.sqlite` is produced by the
/// data-pipeline (Milestone 0) and never written to at runtime.
final class BarcodeDatabase {
    private var db: OpaquePointer?
    private var schema = SchemaFeatures()

    struct BrandException: Equatable {
        enum Action: String {
            case exclude
            case reattribute
        }

        let action: Action
        let actualMaker: String?
        let note: String?
    }

    private struct SchemaFeatures {
        var barcodeMakerOverride = false
        var barcodeOverrideNote = false
        var barcodeMatchBasis = false
        var barcodeEvidenceCount = false
        var exceptions = false
        var prefixes = false
    }

    /// SQLITE_TRANSIENT: tell SQLite to copy bound text immediately, so we don't
    /// have to keep Swift string buffers alive past the bind call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens the active dataset (a self-updated copy if present, else the bundled
    /// one — resolved by `DatasetStore`). Pass an explicit URL to override.
    ///
    /// Fails (returns nil) unless the file is a readable database with non-empty
    /// `brands` and `barcodes` tables. The probe matters because `sqlite3_open`
    /// is lazy — it succeeds even on a corrupt or non-SQLite file, and the error
    /// would otherwise only surface as every lookup silently returning nothing.
    init?(url: URL? = DatasetStore.activeDatabaseURL) {
        guard let url else { return nil }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              (rowCount("brands") ?? 0) > 0,
              (rowCount("barcodes") ?? 0) > 0 else {
            sqlite3_close(db)
            db = nil
            return nil
        }
        schema = detectSchemaFeatures()
    }

    deinit { sqlite3_close(db) }

    /// Resolve a scanned barcode to a verdict + ownership chain.
    func lookup(barcode: String) -> OwnershipResult {
        let query = BarcodeInput.trimmed(barcode)
        for candidate in BarcodeInput.exactLookupCandidates(for: query) {
            if let exact = lookupExact(barcode: candidate, query: query) { return exact }
        }
        if let prefix = lookupPrefix(barcode: query) { return prefix }
        return OwnershipResult(query: query, brandName: nil, parent: nil, verdict: .unknown)
    }

    private func lookupExact(barcode: String, query: String) -> OwnershipResult? {
        let makerOverride = schema.barcodeMakerOverride ? "bc.maker_override" : "NULL"
        let overrideNote = schema.barcodeOverrideNote ? "bc.override_note" : "NULL"
        let matchBasis = schema.barcodeMatchBasis ? "bc.match_basis" : "NULL"
        let evidenceCount = schema.barcodeEvidenceCount ? "bc.evidence_count" : "NULL"
        let sql = """
        SELECT b.brand_name, b.parent, b.is_target,
               \(makerOverride), \(overrideNote), \(matchBasis), \(evidenceCount)
        FROM barcodes bc
        JOIN brands b ON bc.brand_slug = b.brand_slug
        WHERE bc.barcode = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(stmt, 1, barcode, -1, Self.transient)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let brand = columnText(stmt, 0)
            let parent = columnText(stmt, 1)
            let isTarget = sqlite3_column_int(stmt, 2) == 1
            let maker = columnText(stmt, 3)
            let note = columnText(stmt, 4)
            let basis = matchBasisValue(columnText(stmt, 5))
            let evidence = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))

            if let maker {
                return OwnershipResult(query: query, brandName: brand, parent: nil, verdict: .notTarget,
                                       manufacturer: maker, matchBasis: basis, note: note,
                                       evidenceCount: evidence)
            }

            return OwnershipResult(query: query, brandName: brand, parent: parent,
                                   verdict: isTarget ? .match : .notTarget, matchBasis: basis,
                                   evidenceCount: evidence)
        }
        return nil
    }

    private func lookupPrefix(barcode: String) -> OwnershipResult? {
        guard schema.prefixes else { return nil }
        let query = BarcodeInput.trimmed(barcode)
        let candidates = BarcodeInput.prefixLookupCandidates(for: query)
        let sql = """
        SELECT prefix, parent, is_target, evidence_count
        FROM prefixes
        WHERE ? LIKE prefix || '%'
        ORDER BY length(prefix) DESC
        LIMIT 1;
        """
        var best: (prefix: String, parent: String?, evidenceCount: Int?)?

        for candidate in candidates {
            if hasPrefixException(for: candidate) { continue }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, candidate, -1, Self.transient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let isTarget = sqlite3_column_int(stmt, 2) == 1
                if isTarget, let prefix = columnText(stmt, 0) {
                    let parent = columnText(stmt, 1)
                    let evidence = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                        ? nil
                        : Int(sqlite3_column_int(stmt, 3))
                    if best == nil || prefix.count > best!.prefix.count {
                        best = (prefix, parent, evidence)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }

        guard let best else { return nil }
        return OwnershipResult(query: query, brandName: nil, parent: best.parent ?? activeTarget().name,
                               verdict: .match, matchBasis: .inferredFromPrefix,
                               evidenceCount: best.evidenceCount)
    }

    /// Search brands by display name (manual fallback). Case-insensitive substring.
    func searchBrands(query: String, limit: Int = 40) -> [BrandHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sql = """
        SELECT brand_name, parent, is_target
        FROM brands
        WHERE brand_name LIKE ? COLLATE NOCASE
        ORDER BY length(brand_name), brand_name
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, "%\(trimmed)%", -1, Self.transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var hits: [BrandHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            let parent = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let isTarget = sqlite3_column_int(stmt, 2) == 1
            hits.append(BrandHit(brandName: name, parent: parent, isTarget: isTarget))
        }
        return hits
    }

    /// Given OFF brand slugs for a product, return the first that maps to a target
    /// (Nestlé) brand in our table — used by the opt-in online fallback to turn an
    /// online result into a verdict using only the bundled brand list.
    func matchTargetBrand(slugs: [String]) -> (brandSlug: String, brandName: String, parent: String)? {
        let sql = "SELECT brand_name, parent FROM brands WHERE brand_slug = ? AND is_target = 1 LIMIT 1;"
        for slug in slugs {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, slug, -1, Self.transient)
            let hit = sqlite3_step(stmt) == SQLITE_ROW
            let name = hit ? columnText(stmt, 0) : nil
            let parent = hit ? columnText(stmt, 1) : nil
            sqlite3_finalize(stmt)
            if hit { return (slug, name ?? slug, parent ?? activeTarget().name) }
        }
        return nil
    }

    /// Prefix-scoped exceptions are conservative: they suppress inferred matches.
    private func hasPrefixException(for gtin13: String) -> Bool {
        guard schema.exceptions else { return false }
        let sql = """
        SELECT action
        FROM exceptions
        WHERE scope_type = 'prefix'
          AND ? LIKE scope_value || '%'
        LIMIT 1;
        """
        for candidate in prefixExceptionCandidates(for: gtin13) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, candidate, -1, Self.transient)
            let hit = sqlite3_step(stmt) == SQLITE_ROW
            let actionText = hit ? columnText(stmt, 0) : nil
            sqlite3_finalize(stmt)
            if let actionText, BrandException.Action(rawValue: actionText) != nil {
                return true
            }
        }
        return false
    }

    /// Optional W3 rules shipped in the dataset, used by the online fallback.
    /// Only co-brand exceptions can be evaluated from the live OFF response.
    func coBrandException(for targetBrandSlug: String, brandSlugs: [String]) -> BrandException? {
        guard schema.exceptions else { return nil }
        var seen = Set<String>()
        let scopes = brandSlugs.filter { seen.insert($0).inserted }
        guard !scopes.isEmpty else { return nil }

        let sql = """
        SELECT action, actual_maker, note
        FROM exceptions
        WHERE brand_slug = ?
          AND scope_type = 'co_brand'
          AND scope_value = ?
        LIMIT 1;
        """

        for scope in scopes {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, targetBrandSlug, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, scope, -1, Self.transient)
            let hit = sqlite3_step(stmt) == SQLITE_ROW
            let actionText = hit ? columnText(stmt, 0) : nil
            let maker = hit ? columnText(stmt, 1) : nil
            let note = hit ? columnText(stmt, 2) : nil
            sqlite3_finalize(stmt)

            if let actionText, let action = BrandException.Action(rawValue: actionText) {
                return BrandException(action: action, actualMaker: maker, note: note)
            }
        }
        return nil
    }

    /// The first active boycott target declared by the dataset.
    func activeTarget() -> BoycottTarget {
        let sql = """
        SELECT parent
        FROM brands
        WHERE is_target = 1
        GROUP BY parent
        ORDER BY COUNT(*) DESC, parent
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let name = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              !name.isEmpty else {
            return .defaultTarget
        }
        return BoycottTarget(name: name)
    }

    /// Row counts, for the About screen.
    func counts() -> (brands: Int, barcodes: Int) {
        (rowCount("brands") ?? 0, rowCount("barcodes") ?? 0)
    }

    /// nil when the table can't be queried (corrupt / not a database / missing table).
    private func rowCount(_ table: String) -> Int? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func detectSchemaFeatures() -> SchemaFeatures {
        SchemaFeatures(
            barcodeMakerOverride: hasColumn("barcodes", "maker_override"),
            barcodeOverrideNote: hasColumn("barcodes", "override_note"),
            barcodeMatchBasis: hasColumn("barcodes", "match_basis"),
            barcodeEvidenceCount: hasColumn("barcodes", "evidence_count"),
            exceptions: hasTable("exceptions"),
            prefixes: hasTable("prefixes")
        )
    }

    private func hasTable(_ table: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, table, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func hasColumn(_ table: String, _ column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column { return true }
        }
        return false
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, index) else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func matchBasisValue(_ raw: String?) -> MatchBasis {
        let key = raw?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        return key == "inferredfromprefix" || key == "prefix" ? .inferredFromPrefix : .exact
    }

    private func prefixExceptionCandidates(for gtin13: String) -> [String] {
        guard gtin13.hasPrefix("0") else { return [gtin13] }
        return [gtin13, String(gtin13.dropFirst())]
    }

}
