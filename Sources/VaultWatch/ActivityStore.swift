import Foundation

/// Recent file-level sync events for all vaults, newest first.
/// Seeded from each vault's log file on launch so history survives restarts.
final class ActivityStore: ObservableObject {
    static let capacity = 1000
    /// Repeated lines for the same file (e.g. "Uploading file x" then "Upload complete x")
    /// within this window collapse into one event.
    static let dedupeWindow: TimeInterval = 60

    @Published private(set) var events: [SyncEvent] = []

    func add(_ event: SyncEvent) {
        if let i = events.prefix(50).firstIndex(where: {
            $0.vaultID == event.vaultID && $0.path == event.path && $0.kind == event.kind
                && abs(event.date.timeIntervalSince($0.date)) < Self.dedupeWindow
        }) {
            var existing = events.remove(at: i)
            existing.date = max(existing.date, event.date)
            events.insert(existing, at: 0)
            return
        }
        events.insert(event, at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
    }

    func events(for vaultID: UUID, limit: Int) -> [SyncEvent] {
        Array(events.lazy.filter { $0.vaultID == vaultID }.prefix(limit))
    }

    func removeAll(for vaultID: UUID) {
        events.removeAll { $0.vaultID == vaultID }
    }

    /// Counts per kind since a date (e.g. start of today) for one vault.
    func counts(for vaultID: UUID, since: Date) -> (up: Int, down: Int, issues: Int) {
        var up = 0, down = 0, issues = 0
        for e in events where e.vaultID == vaultID {
            if e.date < since { break }   // newest first
            switch e.kind {
            case .upload: up += 1
            case .download: down += 1
            default: if e.kind.isIssue { issues += 1 }
            }
        }
        return (up, down, issues)
    }

    // MARK: - History from log files

    /// Parses the tail of a VaultLogger file ("yyyy-MM-dd HH:mm:ss [ob] <line>").
    func loadHistory(vaultID: UUID, logURL: URL, maxBytes: Int = 1_000_000) {
        DispatchQueue.global(qos: .utility).async {
            guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var parsed: [SyncEvent] = []
            for raw in text.split(separator: "\n") {
                let line = String(raw)
                guard line.count > 26,
                      let tagRange = line.range(of: " [ob] ") ?? line.range(of: " [ob!] ") else { continue }
                let stamp = String(line[..<tagRange.lowerBound])
                let message = String(line[tagRange.upperBound...])
                guard let date = formatter.date(from: stamp),
                      let event = SyncEventParser.parse(message, vaultID: vaultID, date: date) else { continue }
                parsed.append(event)
            }
            DispatchQueue.main.async {
                // Oldest first through add() so de-duplication behaves like live events.
                for e in parsed { self.add(e) }
                self.events.sort { $0.date > $1.date }
            }
        }
    }
}
