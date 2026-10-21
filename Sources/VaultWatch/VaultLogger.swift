import Foundation

/// Per-vault log: file on disk (rotated at 5 MB, one backup) plus an in-memory
/// ring buffer that feeds the live log window.
final class VaultLogger {
    static let maxBytes: UInt64 = 5 * 1024 * 1024
    static let ringSize = 600

    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/VaultWatch", isDirectory: true)
    }

    let fileURL: URL
    private let queue = DispatchQueue(label: "vaultwatch.log")
    private var handle: FileHandle?
    private(set) var ring: [String] = []
    /// Called on the main queue after every appended line.
    var onLine: ((String) -> Void)?

    init(vaultName: String) {
        let safe = vaultName.replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        fileURL = Self.directory.appendingPathComponent("\(safe).log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    func log(_ text: String, source: String = "app") {
        let stamp = Self.formatter.string(from: Date())
        let lines = text.split(whereSeparator: \.isNewline).map { "\(stamp) [\(source)] \($0)" }
        guard !lines.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let blob = lines.joined(separator: "\n") + "\n"
            if let data = blob.data(using: .utf8) { self.write(data) }
            self.ring.append(contentsOf: lines)
            if self.ring.count > Self.ringSize { self.ring.removeFirst(self.ring.count - Self.ringSize) }
            DispatchQueue.main.async { lines.forEach { self.onLine?($0) } }
        }
    }

    func snapshot() -> [String] { queue.sync { ring } }

    private func write(_ data: Data) {
        rotateIfNeeded()
        try? handle?.write(contentsOf: data)
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? UInt64,
              size > Self.maxBytes else { return }
        try? handle?.close()
        let backup = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
