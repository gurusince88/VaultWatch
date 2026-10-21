import Foundation

/// Persists settings as JSON in ~/Library/Application Support/VaultWatch/config.json.
enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VaultWatch", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Config from the pre-rename build (ObSyncBar), imported once if present.
    private static var legacyFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObSyncBar/config.json")
    }

    /// Returns nil on first launch (no config yet) so the caller can auto-discover vaults.
    static func load() -> AppSettings? {
        for url in [fileURL, legacyFileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                if url == legacyFileURL { save(settings) }
                return settings
            }
            if url == fileURL {
                // Unreadable config: keep a copy instead of silently overwriting it.
                let backup = directory.appendingPathComponent("config.json.bak")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
        }
        return nil
    }

    static func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("VaultWatch: failed to save config: \(error)")
        }
    }
}
