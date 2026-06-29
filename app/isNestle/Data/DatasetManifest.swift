import Foundation

/// Describes a published dataset (matches data-pipeline/build_manifest.py).
struct DatasetManifest: Codable, Equatable {
    let version: String          // CalVer "YYYY.MM.DD"
    let sqlite_url: String
    let sqlite_sha256: String
    let sqlite_bytes: Int
    let brands: Int
    let barcodes: Int
}

extension DatasetManifest {
    /// Where the app checks for a newer dataset (rolling release asset).
    static let remoteURL = URL(string:
        "https://github.com/tonylchang/isNestle/releases/download/dataset-latest/manifest.json")!

    /// CalVer compares correctly as plain strings ("2026.06.28" < "2026.07.01").
    func isNewer(than other: DatasetManifest) -> Bool { version > other.version }
}
