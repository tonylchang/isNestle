import Foundation

/// Resolves which dataset the app uses: a self-updated copy in Application Support
/// if present and newer, otherwise the version bundled in the app. Also persists a
/// downloaded dataset + its manifest.
enum DatasetStore {
    private static var appSupport: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var downloadedDB: URL { appSupport.appendingPathComponent("isnestle.sqlite") }
    private static var downloadedManifest: URL { appSupport.appendingPathComponent("dataset_manifest.json") }

    static var bundledManifest: DatasetManifest? {
        guard let url = Bundle.main.url(forResource: "dataset_manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DatasetManifest.self, from: data)
    }

    /// The manifest currently in effect (downloaded if valid & newer than bundle).
    static var activeManifest: DatasetManifest? {
        if let dl = downloadedManifestValue, FileManager.default.fileExists(atPath: downloadedDB.path) {
            if let b = bundledManifest, b.isNewer(than: dl) { return b }  // bundle won (app upgrade)
            return dl
        }
        return bundledManifest
    }

    /// The SQLite file the app should open right now.
    static var activeDatabaseURL: URL? {
        if let dl = downloadedManifestValue, FileManager.default.fileExists(atPath: downloadedDB.path) {
            if let b = bundledManifest, b.isNewer(than: dl) {
                return Bundle.main.url(forResource: "isnestle", withExtension: "sqlite")
            }
            return downloadedDB
        }
        return Bundle.main.url(forResource: "isnestle", withExtension: "sqlite")
    }

    private static var downloadedManifestValue: DatasetManifest? {
        guard let data = try? Data(contentsOf: downloadedManifest) else { return nil }
        return try? JSONDecoder().decode(DatasetManifest.self, from: data)
    }

    /// Atomically install a freshly downloaded dataset + manifest.
    static func install(sqlite tempURL: URL, manifest: DatasetManifest) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: downloadedDB.path) {
            _ = try fm.replaceItemAt(downloadedDB, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: downloadedDB)
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: downloadedManifest, options: .atomic)
    }
}
