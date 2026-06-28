import Foundation
import SQLite3

/// Read-only access to the bundled isNestle dataset (brands + barcodes).
///
/// Dependency-free: uses the system SQLite via the `SQLite3` module — no SPM
/// packages (see STACK.md). The bundled `isnestle.sqlite` is produced by the
/// data-pipeline (Milestone 0) and never written to at runtime.
final class BarcodeDatabase {
    private var db: OpaquePointer?

    /// SQLITE_TRANSIENT: tell SQLite to copy bound text immediately, so we don't
    /// have to keep Swift string buffers alive past the bind call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "isnestle", withExtension: "sqlite") else {
            return nil
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    /// Resolve a scanned barcode to a verdict + ownership chain.
    func lookup(barcode: String) -> OwnershipResult {
        let sql = """
        SELECT b.brand_name, b.parent, b.is_target
        FROM barcodes bc
        JOIN brands b ON bc.brand_slug = b.brand_slug
        WHERE bc.barcode = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return OwnershipResult(query: barcode, brandName: nil, parent: nil, verdict: .unknown)
        }
        sqlite3_bind_text(stmt, 1, barcode, -1, Self.transient)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let brand = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            let parent = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let isTarget = sqlite3_column_int(stmt, 2) == 1
            return OwnershipResult(query: barcode, brandName: brand, parent: parent,
                                   verdict: isTarget ? .match : .notTarget)
        }
        return OwnershipResult(query: barcode, brandName: nil, parent: nil, verdict: .unknown)
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

    /// Row counts, for the About screen.
    func counts() -> (brands: Int, barcodes: Int) {
        func count(_ table: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
        return (count("brands"), count("barcodes"))
    }
}
