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

    /// Detached Ed25519 signature over the exact published bytes of manifest.json.
    static let remoteSignatureURL = URL(string:
        "https://github.com/tonylchang/isNestle/releases/download/dataset-latest/manifest.json.sig")!

    /// Raw Ed25519 public keys trusted to sign the manifest: the CI signing key
    /// plus an offline standby, so a leaked CI key is rotated by swapping the
    /// repo's environment secret — shipped apps already trust the standby.
    /// Key management/rotation runbook: RELEASE.md.
    static let trustedPublicKeys: [Data] = [
        "cc8c8947d16d824d37f84579a587fdf720c1ac83336f503748c9963a1b39bff9",  // primary (CI secret)
        "9d8a106e60076bf8137f92eb80c0d11a4f6f17503e2a02eadbf08c101b344e21",  // standby (offline only)
    ].compactMap(Data.init(hexEncoded:))

    /// Zero-padded UTC timestamps compare correctly as plain strings.
    func isNewer(than other: DatasetManifest) -> Bool { version > other.version }
}

extension Data {
    /// Data from a lowercase/uppercase hex string; nil on malformed input.
    /// (Used for the baked-in public keys; a typo fails tests, not runtime.)
    init?(hexEncoded hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
