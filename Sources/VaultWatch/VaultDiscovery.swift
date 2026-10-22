import Foundation

/// A vault found on this Mac, before it becomes a VaultConfig.
struct DiscoveredVault: Equatable {
    let name: String
    let path: String
    /// true when `ob sync-setup` has already been run for this path,
    /// so VaultWatch can start syncing it immediately.
    let syncConfigured: Bool
}

/// Finds Obsidian vaults on this Mac from three sources, deduped by path:
/// 1. `ob sync-list-local --json`  — vaults already configured for Headless Sync
/// 2. Obsidian's own vault registry — every vault the desktop app knows about
/// 3. The iCloud Obsidian folder    — vaults created on iPhone/iPad that the
///    desktop app may never have opened
enum VaultDiscovery {

    /// Blocking (spawns `ob`); call off the main thread except at first launch.
    static func discover(_ binaries: ResolvedBinaries?) -> [DiscoveredVault] {
        var byKey: [String: DiscoveredVault] = [:]
        var order: [String] = []

        func add(_ path: String, configured: Bool) {
            let clean = normalize(path)
            guard !clean.isEmpty, isVaultDirectory(clean, requireMarker: !configured) else { return }
            let key = dedupeKey(clean)
            if let existing = byKey[key] {
                // Keep one entry; "sync-configured" wins so it starts enabled.
                if configured && !existing.syncConfigured {
                    byKey[key] = DiscoveredVault(name: existing.name, path: existing.path, syncConfigured: true)
                }
                return
            }
            byKey[key] = DiscoveredVault(
                name: URL(fileURLWithPath: clean).lastPathComponent,
                path: clean,
                syncConfigured: configured
            )
            order.append(key)
        }

        for p in syncConfiguredPaths(binaries) { add(p, configured: true) }
        for p in registryPaths() { add(p, configured: false) }
        for p in iCloudVaultPaths() { add(p, configured: false) }

        return order.compactMap { byKey[$0] }
    }

    // MARK: - Source 1: ob sync-list-local

    private static func syncConfiguredPaths(_ binaries: ResolvedBinaries?) -> [String] {
        guard let b = binaries else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: b.ob)
        p.arguments = ["sync-list-local", "--json"]
        p.environment = b.environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        struct Listing: Decodable {
            struct Vault: Decodable { let path: String }
            let vaults: [Vault]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        return listing.vaults.map(\.path)
    }

    // MARK: - Source 2: Obsidian's vault registry

    /// Desktop Obsidian keeps every vault it knows in
    /// ~/Library/Application Support/obsidian/obsidian.json:
    ///   {"vaults": {"<id>": {"path": "/Users/…/Vault", "ts": …, "open": true}, …}}
    /// Parsed with JSONSerialization so extra keys or shape changes don't break it.
    private static func registryPaths() -> [String] {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
        guard
            let data = try? Data(contentsOf: url),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let vaults = root["vaults"] as? [String: Any]
        else { return [] }
        return vaults.values
            .compactMap { ($0 as? [String: Any])?["path"] as? String }
            .sorted()   // dictionary order is random; keep results stable
    }

    // MARK: - Source 3: iCloud Obsidian folder

    /// Vaults synced via "Store in iCloud" live one level under
    /// ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/.
    private static func iCloudVaultPaths() -> [String] {
        let docs = NSHomeDirectory() + "/Library/Mobile Documents/iCloud~md~obsidian/Documents"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: docs) else { return [] }
        return entries.sorted().map { docs + "/" + $0 }
    }

    // MARK: - Helpers

    /// A vault is a directory; unconfigured candidates must also contain `.obsidian`
    /// (sync-configured paths are trusted even before the first `ob sync` creates it).
    private static func isVaultDirectory(_ path: String, requireMarker: Bool) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard requireMarker else { return true }
        return FileManager.default.fileExists(atPath: path + "/.obsidian")
    }

    /// Canonical absolute path: expands ~, strips trailing "/", resolves symlinks.
    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
            .resolvingSymlinksInPath().path
    }

    /// APFS is case-insensitive by default, so compare case-insensitively.
    static func dedupeKey(_ path: String) -> String { normalize(path).lowercased() }
}
