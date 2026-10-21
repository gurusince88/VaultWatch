import Foundation
import AppKit

/// Splits raw pipe chunks into complete lines.
private final class LineBuffer {
    private var buf = Data()

    func feed(_ data: Data) -> [String] {
        buf.append(data)
        var lines: [String] = []
        while let idx = buf.firstIndex(of: 0x0A) {
            let lineData = buf.subdata(in: buf.startIndex..<idx)
            buf.removeSubrange(buf.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8) { lines.append(s) }
        }
        return lines
    }

    func flush() -> String? {
        defer { buf.removeAll() }
        guard !buf.isEmpty else { return nil }
        return String(data: buf, encoding: .utf8)
    }
}

private final class DataBox {
    var data = Data()
}

/// Owns the `ob sync` child process for ONE vault: preflight, spawn, backoff restarts,
/// graceful SIGTERM shutdown, duplicate-process guard, and log capture.
/// All mutable state is confined to `queue`.
final class VaultSupervisor {
    let vault: VaultConfig
    let logger: VaultLogger
    /// Always invoked on the main queue.
    var onChange: ((UUID, VaultRuntime) -> Void)?
    /// File-level sync events parsed from ob output. Always invoked on the main queue.
    var onEvent: ((SyncEvent) -> Void)?

    private let binaries: ResolvedBinaries
    private let maxFailures: Int
    private let queue: DispatchQueue

    private var runtime = VaultRuntime()
    private var process: Process?
    private var wantsRunning = false
    private var stoppingProcess = false
    private var stopPhase: SyncPhase = .stopped
    private var authFailed = false
    private var duplicateReported = false
    private var launchedAt: Date?
    private var restartItem: DispatchWorkItem?
    private var intervalItem: DispatchWorkItem?

    private static let backoff: [TimeInterval] = [2, 5, 15, 60, 120]
    // Real `ob` messages (from obsidian-headless cli.js) plus a few generic fallbacks.
    private static let authPatterns = [
        "no account logged in", "failed to authenticate", "encryption key not found",
        "failed to validate password", "not logged in", "unauthorized", "session expired"
    ]
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    init(vault: VaultConfig, binaries: ResolvedBinaries, maxFailures: Int) {
        self.vault = vault
        self.binaries = binaries
        self.maxFailures = maxFailures
        self.queue = DispatchQueue(label: "vaultwatch.vault.\(vault.id.uuidString)")
        self.logger = VaultLogger(vaultName: vault.name)
    }

    // MARK: - Public controls (all async, safe from any thread)

    func start() {
        queue.async {
            self.wantsRunning = true
            self.runtime.consecutiveFailures = 0
            self.launch()
        }
    }

    func stop(as phase: SyncPhase = .stopped) {
        queue.async {
            self.wantsRunning = false
            self.restartItem?.cancel()
            self.intervalItem?.cancel()
            self.stopPhase = phase
            if let p = self.process {
                self.terminate(p)
            } else {
                self.update { $0.phase = phase; $0.detail = ""; $0.pid = nil }
            }
        }
    }

    func restart() {
        queue.async {
            self.wantsRunning = true
            self.runtime.consecutiveFailures = 0
            self.restartItem?.cancel()
            self.intervalItem?.cancel()
            if let p = self.process {
                self.terminate(p)          // handleExit relaunches because wantsRunning == true
            } else {
                self.launch()
            }
        }
    }

    /// "Sync now": interval mode runs a pass immediately; continuous mode restarts the watcher.
    func syncNow() {
        if vault.continuous { restart() } else { start() }
    }

    /// Stop any other `ob sync` already running on this vault, then start ours.
    func takeOver() {
        queue.async {
            let pids = Self.externalSyncPIDs(for: self.vault.path)
            self.logger.log("taking over from external ob sync PIDs: \(pids)")
            pids.forEach { kill($0, SIGTERM) }
            var waited = 0
            while !Self.externalSyncPIDs(for: self.vault.path).isEmpty && waited < 50 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 1
            }
            self.wantsRunning = true
            self.runtime.consecutiveFailures = 0
            self.launch()
        }
    }

    /// Blocking shutdown for app quit / logout: SIGTERM, wait, SIGKILL only as a last resort.
    func shutdownSync(timeout: TimeInterval = 10) {
        var proc: Process?
        queue.sync {
            self.wantsRunning = false
            self.restartItem?.cancel()
            self.intervalItem?.cancel()
            self.stoppingProcess = true
            proc = self.process
        }
        guard let p = proc, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Re-reads `ob sync-status` for display. Calls back on main.
    func refreshStatusText(_ completion: @escaping (String) -> Void) {
        queue.async {
            let r = self.runCapture(["sync-status", "--path", self.vault.path], timeout: 20)
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.update { $0.statusText = text }
            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: - Lifecycle (queue-confined)

    private func launch() {
        guard wantsRunning, process == nil else { return }
        restartItem?.cancel()
        intervalItem?.cancel()
        update { $0.phase = .starting; $0.detail = ""; $0.warning = "" }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            block(.blocked, "Vault folder not found: \(vault.path)")
            return
        }

        // Single-instance guard.
        let others = Self.externalSyncPIDs(for: vault.path)
        if !others.isEmpty {
            let list = others.map(String.init).joined(separator: ", ")
            block(.blocked, "Another `ob sync` is already running on this vault (PID \(list)).")
            return
        }

        // Preflight: is this vault configured for Headless Sync?
        let pre = runCapture(["sync-status", "--path", vault.path], timeout: 20)
        let preText = pre.output.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.statusText = preText }
        guard pre.status == 0, preText.contains("Vault:") else {
            logger.log(preText.isEmpty ? "sync-status exited \(pre.status) with no output" : preText, source: "preflight")
            block(.needsSetup, "Vault isn't set up for Headless Sync yet. Use “Set up in Terminal…”.", notify: true)
            return
        }

        // Non-blocking warning: desktop Obsidian + Headless Sync on one device can conflict.
        let desktopRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty
        let warning = desktopRunning
            ? "Obsidian desktop is running. Keep desktop Sync off for this vault; both syncing on one device can cause conflicts."
            : ""
        if desktopRunning { logger.log("warning: \(warning)") }

        spawn(warning: warning)
    }

    private func spawn(warning: String) {
        var args = ["sync", "--path", vault.path]
        if vault.continuous { args.append("--continuous") }
        args.append(contentsOf: vault.extraArgs)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaries.ob)
        p.arguments = args
        p.environment = binaries.environment
        p.currentDirectoryURL = URL(fileURLWithPath: vault.path)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        attach(out, source: "ob")
        attach(err, source: "ob!")
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.handleExit(proc) }
        }

        logger.log("starting: \(binaries.ob) \(args.joined(separator: " "))")
        do {
            try p.run()
        } catch {
            logger.log("failed to launch: \(error)")
            process = nil
            registerFailure(status: -1, ranFor: 0)
            return
        }

        process = p
        launchedAt = Date()
        stoppingProcess = false
        authFailed = false
        update {
            $0.pid = p.processIdentifier
            $0.phase = vault.continuous ? .running : .syncing
            $0.detail = vault.continuous ? "Watching for changes" : "Sync pass in progress"
            $0.warning = warning
            $0.lastActivity = Date()
        }
    }

    private func attach(_ pipe: Pipe, source: String) {
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self = self else { handle.readabilityHandler = nil; return }
            if data.isEmpty {   // EOF
                handle.readabilityHandler = nil
                if let tail = buffer.flush() { self.queue.async { self.ingest(tail, source: source) } }
                return
            }
            let lines = buffer.feed(data)
            if !lines.isEmpty { self.queue.async { lines.forEach { self.ingest($0, source: source) } } }
        }
    }

    private func ingest(_ rawLine: String, source: String) {
        let range = NSRange(rawLine.startIndex..., in: rawLine)
        let line = Self.ansi.stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        logger.log(line, source: source)
        let now = Date()

        // Connection state from ob's own status lines.
        var newConnection: ConnectionState?
        if line.hasPrefix("Connecting...") || line.hasPrefix("Scanning for changes") {
            newConnection = .connecting
        } else if line.hasPrefix("Connection successful") {
            newConnection = .syncing("")
        } else if line.hasPrefix("Fully synced") {
            newConnection = .upToDate(now)
        } else if line.hasPrefix("Waiting to connect") {
            newConnection = .offline
        } else if let path = SyncEventParser.inProgressPath(line) {
            newConnection = .syncing(path)
        }
        update {
            $0.lastLine = line
            $0.lastActivity = now
            if let c = newConnection { $0.connection = c }
        }

        if let event = SyncEventParser.parse(line, vaultID: vault.id, date: now) {
            DispatchQueue.main.async { self.onEvent?(event) }
        }

        if line.hasPrefix("Another sync instance is already running") {
            duplicateReported = true
        }

        let lower = line.lowercased()
        if !authFailed, Self.authPatterns.contains(where: { lower.contains($0) }), let p = process {
            authFailed = true
            logger.log("auth problem detected; stopping so it isn't retried in a loop")
            terminate(p)
        }
    }

    private func handleExit(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        let status = proc.terminationStatus
        let ranFor = launchedAt.map { Date().timeIntervalSince($0) } ?? 0
        let how = proc.terminationReason == .exit ? "exit" : "signal"
        logger.log("ob exited (\(how) \(status)) after \(Int(ranFor))s")
        update { $0.pid = nil; $0.connection = .unknown }

        // ob's own exit codes: 2 = not logged in / bad password, 3 = vault not configured.
        if !stoppingProcess && proc.terminationReason == .exit {
            if status == 2 { authFailed = true }
            if status == 3 {
                block(.needsSetup, "Vault isn't set up for Headless Sync. Use “Set Up in Terminal…”.", notify: true)
                return
            }
            if duplicateReported {
                duplicateReported = false
                block(.blocked, "Another `ob sync` is already running on this vault.")
                return
            }
        }

        if authFailed {
            authFailed = false
            stoppingProcess = false
            block(.needsSetup, "Login required. Use “Log in via Terminal…” (ob login).", notify: true)
            return
        }

        if stoppingProcess {
            stoppingProcess = false
            if wantsRunning {
                launch()                                   // restart() / syncNow() path
            } else {
                update { $0.phase = stopPhase; $0.detail = "" }
            }
            return
        }

        guard wantsRunning else {
            update { $0.phase = .stopped; $0.detail = "" }
            return
        }

        if !vault.continuous && status == 0 {
            runtime.consecutiveFailures = 0
            scheduleNextInterval()
            return
        }
        registerFailure(status: status, ranFor: ranFor)
    }

    private func registerFailure(status: Int32, ranFor: TimeInterval) {
        if ranFor > 60 { runtime.consecutiveFailures = 0 }   // it was healthy for a while
        runtime.consecutiveFailures += 1
        let n = runtime.consecutiveFailures

        if n >= maxFailures {
            wantsRunning = false
            update {
                $0.phase = .failed
                $0.detail = "Gave up after \(n) failed starts (last exit \(status)). Check the log."
            }
            Notifier.post(
                title: "VaultWatch: sync stopped",
                body: "\(vault.name) failed \(n) times in a row. Open the menu to view the log."
            )
            return
        }

        let delay = Self.backoff[min(n - 1, Self.backoff.count - 1)]
        update {
            $0.phase = .backoff
            $0.detail = "Restarting in \(Int(delay))s (attempt \(n) of \(maxFailures))"
        }
        let item = DispatchWorkItem { [weak self] in self?.launch() }
        restartItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleNextInterval() {
        let minutes = max(1, vault.intervalMinutes)
        update { $0.phase = .running; $0.detail = "Next sync in \(minutes) min" }
        let item = DispatchWorkItem { [weak self] in self?.launch() }
        intervalItem = item
        queue.asyncAfter(deadline: .now() + Double(minutes) * 60, execute: item)
    }

    private func terminate(_ p: Process) {
        stoppingProcess = true
        p.terminate()   // SIGTERM
        queue.asyncAfter(deadline: .now() + 8) {
            if p.isRunning {
                self.logger.log("did not exit after SIGTERM; sending SIGKILL")
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    private func block(_ phase: SyncPhase, _ detail: String, notify: Bool = false) {
        wantsRunning = false
        update { $0.phase = phase; $0.detail = detail; $0.pid = nil }
        logger.log("\(phase.label): \(detail)")
        if notify { Notifier.post(title: "VaultWatch: \(vault.name)", body: detail) }
    }

    private func update(_ change: (inout VaultRuntime) -> Void) {
        change(&runtime)
        let snapshot = runtime
        let id = vault.id
        DispatchQueue.main.async { self.onChange?(id, snapshot) }
    }

    // MARK: - Helpers

    private func runCapture(_ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaries.ob)
        p.arguments = args
        p.environment = binaries.environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "failed to launch ob: \(error)") }

        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            return (-2, "timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }

    /// PIDs of `ob sync ...` processes (not ours) running against this vault path.
    static func externalSyncPIDs(for path: String) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-wwaxo", "pid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let me = getpid()
        var pids: [Int32] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]), pid != me else { continue }
            let cmd = String(line[line.index(after: space)...])
            let tokens = cmd.split(separator: " ").map(String.init)
            let isObSync = tokens.contains("sync")
                && (cmd.contains("obsidian-headless") || tokens.contains(where: { $0.hasSuffix("/ob") }))
            if isObSync && cmd.contains(path) { pids.append(pid) }
        }
        return pids
    }
}
