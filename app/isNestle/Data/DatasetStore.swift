import Foundation

/// File locations used by `DatasetStore`. The live app uses the bundle plus
/// Application Support; tests pass temporary URLs so update behavior is isolated.
struct DatasetStoreConfiguration {
    let bundledDatabaseURL: URL?
    let bundledManifestURL: URL?
    let appSupportDirectory: URL

    static var live: DatasetStoreConfiguration {
        DatasetStoreConfiguration(
            bundledDatabaseURL: Bundle.main.url(forResource: "isnestle", withExtension: "sqlite"),
            bundledManifestURL: Bundle.main.url(forResource: "dataset_manifest", withExtension: "json"),
            appSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
    }

    var downloadedDatabaseURL: URL { appSupportDirectory.appendingPathComponent("isnestle.sqlite") }
    var downloadedManifestURL: URL { appSupportDirectory.appendingPathComponent("dataset_manifest.json") }
}

/// Resolves which dataset the app uses: a self-updated copy in Application Support
/// if present and newer, otherwise the version bundled in the app. Also persists a
/// downloaded dataset + its manifest.
enum DatasetStore {
    static var bundledManifest: DatasetManifest? {
        bundledManifest(in: .live)
    }

    static func bundledManifest(in configuration: DatasetStoreConfiguration) -> DatasetManifest? {
        guard let url = configuration.bundledManifestURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DatasetManifest.self, from: data)
    }

    /// The manifest currently in effect (downloaded if valid & newer than bundle).
    static var activeManifest: DatasetManifest? {
        activeManifest(in: .live)
    }

    static func activeManifest(in configuration: DatasetStoreConfiguration) -> DatasetManifest? {
        if let dl = downloadedManifestValue(in: configuration),
           FileManager.default.fileExists(atPath: configuration.downloadedDatabaseURL.path) {
            if let b = bundledManifest(in: configuration), b.isNewer(than: dl) { return b }  // bundle won (app upgrade)
            return dl
        }
        return bundledManifest(in: configuration)
    }

    /// The SQLite file the app should open right now.
    static var activeDatabaseURL: URL? {
        activeDatabaseURL(in: .live)
    }

    static func activeDatabaseURL(in configuration: DatasetStoreConfiguration) -> URL? {
        if let dl = downloadedManifestValue(in: configuration),
           FileManager.default.fileExists(atPath: configuration.downloadedDatabaseURL.path) {
            if let b = bundledManifest(in: configuration), b.isNewer(than: dl) {
                return configuration.bundledDatabaseURL
            }
            return configuration.downloadedDatabaseURL
        }
        return configuration.bundledDatabaseURL
    }

    /// Open the dataset the app should use. If the downloaded copy turns out to
    /// be unreadable (corrupted on disk after install), discard it — so the next
    /// daily check re-downloads instead of staying wedged — and fall back to the
    /// bundled dataset rather than leaving the app with no database at all.
    static func openActiveDatabase(in configuration: DatasetStoreConfiguration = .live) -> BarcodeDatabase? {
        let active = activeDatabaseURL(in: configuration)
        if let db = BarcodeDatabase(url: active) { return db }
        guard let bundled = configuration.bundledDatabaseURL, active != bundled else { return nil }
        try? FileManager.default.removeItem(at: configuration.downloadedDatabaseURL)
        try? FileManager.default.removeItem(at: configuration.downloadedManifestURL)
        return BarcodeDatabase(url: bundled)
    }

    private static func downloadedManifestValue(in configuration: DatasetStoreConfiguration) -> DatasetManifest? {
        guard let data = try? Data(contentsOf: configuration.downloadedManifestURL) else { return nil }
        return try? JSONDecoder().decode(DatasetManifest.self, from: data)
    }

    /// Atomically install a freshly downloaded dataset + manifest.
    static func install(sqlite tempURL: URL, manifest: DatasetManifest) throws {
        try install(sqlite: tempURL, manifest: manifest, in: .live)
    }

    static func install(sqlite tempURL: URL, manifest: DatasetManifest,
                        in configuration: DatasetStoreConfiguration) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configuration.appSupportDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: configuration.downloadedDatabaseURL.path) {
            _ = try fm.replaceItemAt(configuration.downloadedDatabaseURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: configuration.downloadedDatabaseURL)
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: configuration.downloadedManifestURL, options: .atomic)
    }
}
