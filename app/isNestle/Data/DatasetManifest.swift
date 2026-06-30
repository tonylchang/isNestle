import Foundation

/// Describes a published dataset (matches data-pipeline/build_manifest.py).
struct DatasetManifest: Codable, Equatable {
    let version: String          // UTC CalVer timestamp "YYYY.MM.DD.HHMM"
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

    /// Zero-padded UTC timestamps compare correctly as plain strings.
    func isNewer(than other: DatasetManifest) -> Bool { version > other.version }
}
