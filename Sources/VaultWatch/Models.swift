import Foundation

/// One vault that VaultWatch keeps synced via `ob sync --path <path> [--continuous]`.
struct VaultConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
    /// true  -> `ob sync --path <path> --continuous` (long-running child process)
    /// false -> `ob sync --path <path>` re-run every `intervalMinutes`
    var continuous: Bool = true
    var enabled: Bool = true
    var intervalMinutes: Int = 5
    var extraArgs: [String] = []

    init(name: String, path: String, continuous: Bool = true) {
        self.name = name
        self.path = path
        self.continuous = continuous
    }

    // Tolerant decoding so hand-edited configs with missing keys still load.
    enum CodingKeys: String, CodingKey { case id, name, path, continuous, enabled, intervalMinutes, extraArgs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        continuous = try c.decodeIfPresent(Bool.self, forKey: .continuous) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
    }
}

struct AppSettings: Codable, Equatable {
    var vaults: [VaultConfig] = []
    /// After this many consecutive failed starts the supervisor stops retrying and notifies.
    var maxConsecutiveFailures: Int = 5
}

enum SyncPhase: String {
    case stopped      // not running (disabled or user stopped)
    case starting     // preflight + spawn in progress
    case running      // child alive (continuous) or waiting for next interval
    case syncing      // interval mode: a sync pass is executing
    case backoff      // crashed, waiting to restart
    case needsSetup   // `ob sync-status` says the vault is not configured
    case failed       // gave up after too many failures
    case paused       // user paused
    case blocked      // duplicate process / missing folder / missing binary

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Watching"
        case .syncing: return "Syncing…"
        case .backoff: return "Restarting…"
        case .needsSetup: return "Needs setup"
        case .failed: return "Failed"
        case .paused: return "Paused"
        case .blocked: return "Blocked"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .syncing, .starting, .backoff: return "arrow.triangle.2.circlepath"
        case .paused, .stopped: return "pause.circle"
        case .needsSetup, .blocked: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var isProblem: Bool {
        switch self {
        case .needsSetup, .failed, .blocked: return true
        default: return false
        }
    }
}

/// What `ob` is doing right now, derived from its output.
enum ConnectionState: Equatable {
    case unknown
    case connecting
    case syncing(String)   // current file
    case upToDate(Date)
    case offline

    var label: String {
        switch self {
        case .unknown: return ""
        case .connecting: return "Connecting…"
        case .syncing(let path):
            return path.isEmpty ? "Checking for changes…" : "Syncing \((path as NSString).lastPathComponent)"
        case .upToDate: return "Up to date"
        case .offline: return "Waiting for connection"
        }
    }
}

/// Live, UI-facing state for one vault.
struct VaultRuntime: Equatable {
    var phase: SyncPhase = .stopped
    var connection: ConnectionState = .unknown
    var detail: String = ""
    var pid: Int32? = nil
    var lastActivity: Date? = nil
    var lastLine: String = ""
    var consecutiveFailures: Int = 0
    var statusText: String = ""   // last `ob sync-status` output
    var warning: String = ""      // non-blocking, e.g. desktop Obsidian is running
}

// MARK: - Sync activity

enum SyncEventKind: String, CaseIterable, Codable {
    case upload, download, deleteLocal, deleteRemote, merge, conflict, skipped, error

    var label: String {
        switch self {
        case .upload: return "Uploaded"
        case .download: return "Downloaded"
        case .deleteLocal: return "Deleted locally"
        case .deleteRemote: return "Deleted on server"
        case .merge: return "Merged"
        case .conflict: return "Conflict"
        case .skipped: return "Skipped"
        case .error: return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .deleteLocal, .deleteRemote: return "trash.circle.fill"
        case .merge: return "arrow.triangle.merge"
        case .conflict: return "exclamationmark.2"
        case .skipped: return "forward.circle"
        case .error: return "xmark.circle.fill"
        }
    }

    var isIssue: Bool { self == .conflict || self == .skipped || self == .error }
}

struct SyncEvent: Identifiable, Equatable {
    let id = UUID()
    let vaultID: UUID
    let kind: SyncEventKind
    let path: String
    var date: Date

    var fileName: String { (path as NSString).lastPathComponent }
    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }
}

/// Turns `ob` output lines into file-level events.
/// `ob` logs as `console.log(message, path)`, i.e. "<message> <path>".
enum SyncEventParser {
    // Longest prefixes first so "Deleting remote file" wins over "Deleting".
    private static let prefixes: [(String, SyncEventKind)] = [
        ("Deleting remote folder ", .deleteRemote),
        ("Deleting remote file ", .deleteRemote),
        ("Removing local-only folder ", .deleteLocal),
        ("Removing local-only file ", .deleteLocal),
        ("Merging conflicted file ", .merge),
        ("Renaming conflicted file ", .conflict),
        ("Conflicted copy stored ", .conflict),
        ("Merge successful ", .merge),
        ("Upload complete ", .upload),
        ("Uploading file ", .upload),
        ("Uploading ", .upload),
        ("Downloading ", .download),
        ("Downloaded ", .download),
        ("Restoring ", .download),
        ("Reverting ", .download),
        ("Deleting ", .deleteLocal),
        ("Skipped ", .skipped),
    ]

    static func parse(_ line: String, vaultID: UUID, date: Date = Date()) -> SyncEvent? {
        for (prefix, kind) in prefixes where line.hasPrefix(prefix) {
            let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return SyncEvent(vaultID: vaultID, kind: kind, path: path, date: date)
        }
        // "File too large to sync (12 MB, max 5 MB) path/to/file.mov"
        if line.hasPrefix("File too large to sync"), let close = line.firstIndex(of: ")") {
            let path = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return SyncEvent(vaultID: vaultID, kind: .skipped, path: path, date: date) }
        }
        if line.hasPrefix("Merge failed.") {
            return SyncEvent(vaultID: vaultID, kind: .error, path: line, date: date)
        }
        return nil
    }

    /// Path currently being transferred, for the "Syncing <file>" status.
    static func inProgressPath(_ line: String) -> String? {
        for prefix in ["Uploading file ", "Downloading "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }
}
