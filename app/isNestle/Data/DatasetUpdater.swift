import CryptoKit
import Foundation

/// Checks for and installs a newer dataset from the rolling GitHub release.
/// Privacy: this is a plain file download — it reveals nothing about what was
/// scanned (see the privacy policy). It runs only against the static release host.
enum DatasetUpdater {
    enum Result: Equatable {
        case upToDate
        case updated(DatasetManifest)
        case failed(String)
    }

    static func checkAndUpdate() async -> Result {
        guard let current = DatasetStore.activeManifest else {
            return .failed("No active dataset")
        }
        // 1. Fetch the remote manifest.
        let remote: DatasetManifest
        do {
            var req = URLRequest(url: DatasetManifest.remoteURL)
            req.timeoutInterval = 15
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .failed("Manifest unavailable") }
            remote = try JSONDecoder().decode(DatasetManifest.self, from: data)
        } catch {
            return .failed("Couldn’t reach update server")
        }

        guard remote.isNewer(than: current) else { return .upToDate }

        // 2. Download the new SQLite to a temp file.
        guard let url = URL(string: remote.sqlite_url) else { return .failed("Bad dataset URL") }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            let (tempURL, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .failed("Download failed") }

            // 3. Verify size + SHA-256 before trusting it.
            let data = try Data(contentsOf: tempURL)
            guard data.count == remote.sqlite_bytes else { return .failed("Size mismatch") }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == remote.sqlite_sha256 else { return .failed("Checksum mismatch") }

            // 4. Install atomically.
            try DatasetStore.install(sqlite: tempURL, manifest: remote)
            return .updated(remote)
        } catch {
            return .failed("Update failed")
        }
    }
}
