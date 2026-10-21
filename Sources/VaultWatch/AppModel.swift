import SwiftUI
import AppKit

/// Owns settings + one VaultSupervisor per vault, and publishes live state to the UI.
/// All access is on the main thread (supervisor callbacks are delivered on main).
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings
    @Published var runtimes: [UUID: VaultRuntime] = [:]
    @Published var binaries: ResolvedBinaries?
    @Published var launchAtLogin: Bool = LoginItem.isEnabled

    /// File-level sync activity across all vaults.
    let activity = ActivityStore()

    private var supervisors: [UUID: VaultSupervisor] = [:]
    private var userPaused = Set<UUID>()
    private var sleptVaults = Set<UUID>()
    private var historyLoaded = Set<UUID>()

    private init() {
        let bins = BinaryResolver.resolve()
        let loaded = ConfigStore.load()
        // First launch: pick up every vault already configured with `ob sync-setup`.
        let initial = loaded ?? AppSettings(vaults: AppModel.discoverVaults(bins))
        settings = initial
        binaries = bins
        if loaded == nil { ConfigStore.save(initial) }

        Notifier.requestAuthorization()
        rebuildAll()
        observeSystemEvents()
        startAll()
    }

    /// Vaults configured locally for Headless Sync (`ob sync-list-local --json`).
    static func discoverVaults(_ binaries: ResolvedBinaries?) -> [VaultConfig] {
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
            struct Vault: Decodable { let id: String?; let path: String }
            let vaults: [Vault]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        return listing.vaults.map {
            VaultConfig(name: URL(fileURLWithPath: $0.path).lastPathComponent, path: $0.path)
        }
    }

    /// Adds any `ob`-configured vaults that aren't in the list yet. Returns how many were added.
    @discardableResult
    func importConfiguredVaults() -> Int {
        let known = Set(settings.vaults.map(\.path))
        let new = Self.discoverVaults(binaries).filter { !known.contains($0.path) }
        for v in new {
            settings.vaults.append(v)
            makeSupervisor(for: v)
            supervisors[v.id]?.start()
        }
        if !new.isEmpty { save() }
        return new.count
    }

    // MARK: - Derived UI state

    /// Shows a short status label ("ob ✓") next to the icon in the menu bar.
    @Published var showMenuBarText: Bool = UserDefaults.standard.object(forKey: "showMenuBarText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarText, forKey: "showMenuBarText") }
    }

    private enum Overall { case ok, busy, problem, paused }

    private var overall: Overall {
        let phases = runtimes.values.map(\.phase)
        if phases.contains(where: { $0.isProblem }) { return .problem }
        if phases.contains(where: { $0 == .syncing || $0 == .starting || $0 == .backoff }) { return .busy }
        if runtimes.values.contains(where: {
            if case .syncing = $0.connection { return true }
            return $0.connection == .connecting
        }) { return .busy }
        if phases.isEmpty || phases.allSatisfy({ $0 == .paused || $0 == .stopped }) { return .paused }
        return .ok
    }

    // Sync-arrow icons (not clouds) so it doesn't blend in with OneDrive/iCloud.
    var menuBarSymbol: String {
        switch overall {
        case .ok: return "arrow.triangle.2.circlepath.circle.fill"
        case .busy: return "arrow.triangle.2.circlepath.circle"
        case .problem: return "exclamationmark.arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        }
    }

    var menuBarText: String {
        switch overall {
        case .ok: return "ob ✓"
        case .busy: return "ob …"
        case .problem: return "ob !"
        case .paused: return "ob ⏸"
        }
    }

    var binariesHelp: String? {
        binaries == nil
            ? "`ob` was not found. Install it with: npm install -g obsidian-headless (needs Node 22+), then re-check."
            : nil
    }

    func logger(for id: UUID) -> VaultLogger? { supervisors[id]?.logger }

    // MARK: - Lifecycle

    private func rebuildAll() {
        supervisors.values.forEach { $0.onChange = nil }
        supervisors.removeAll()
        runtimes.removeAll()
        for v in settings.vaults { makeSupervisor(for: v) }
    }

    private func makeSupervisor(for vault: VaultConfig) {
        guard let binaries = binaries else {
            runtimes[vault.id] = VaultRuntime(phase: .blocked, detail: "`ob` not found")
            return
        }
        let s = VaultSupervisor(vault: vault, binaries: binaries, maxFailures: settings.maxConsecutiveFailures)
        s.onChange = { [weak self] id, rt in self?.runtimes[id] = rt }
        s.onEvent = { [weak self] event in self?.activity.add(event) }
        supervisors[vault.id] = s
        runtimes[vault.id] = VaultRuntime()
        if !historyLoaded.contains(vault.id) {
            historyLoaded.insert(vault.id)
            activity.loadHistory(vaultID: vault.id, logURL: s.logger.fileURL)
        }
    }

    func startAll() {
        for v in settings.vaults where v.enabled && !userPaused.contains(v.id) {
            supervisors[v.id]?.start()
        }
    }

    func recheckBinaries() {
        shutdownAll()
        binaries = BinaryResolver.resolve()
        rebuildAll()
        startAll()
    }

    /// Called on quit / logout / power off. SIGTERM, wait, then SIGKILL only if needed.
    func shutdownAll() {
        supervisors.values.forEach { $0.shutdownSync(timeout: 10) }
    }

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.shutdownAll()
        }
    }

    private func handleSleep() {
        for (id, s) in supervisors where !userPaused.contains(id) {
            sleptVaults.insert(id)
            s.stop(as: .paused)
        }
    }

    private func handleWake() {
        // Give Wi-Fi a few seconds to come back before relaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            for id in self.sleptVaults where !self.userPaused.contains(id) {
                self.supervisors[id]?.start()
            }
            self.sleptVaults.removeAll()
        }
    }

    // MARK: - Vault management

    func addVault(path: String) {
        let url = URL(fileURLWithPath: path)
        guard !settings.vaults.contains(where: { $0.path == url.path }) else { return }
        let v = VaultConfig(name: url.lastPathComponent, path: url.path)
        settings.vaults.append(v)
        save()
        makeSupervisor(for: v)
        supervisors[v.id]?.start()
    }

    func removeVault(_ id: UUID) {
        supervisors[id]?.onChange = nil
        supervisors[id]?.onEvent = nil
        activity.removeAll(for: id)
        supervisors[id]?.shutdownSync(timeout: 10)
        supervisors[id] = nil
        runtimes[id] = nil
        userPaused.remove(id)
        settings.vaults.removeAll { $0.id == id }
        save()
    }

    /// Apply a config change and restart that vault's supervisor with the new settings.
    func updateVault(_ id: UUID, _ change: (inout VaultConfig) -> Void) {
        guard let idx = settings.vaults.firstIndex(where: { $0.id == id }) else { return }
        supervisors[id]?.onChange = nil          // drop stale callbacks from the old supervisor
        supervisors[id]?.onEvent = nil
        supervisors[id]?.shutdownSync(timeout: 10)
        change(&settings.vaults[idx])
        save()
        let v = settings.vaults[idx]
        makeSupervisor(for: v)
        if userPaused.contains(id) {
            runtimes[id] = VaultRuntime(phase: .paused)
        } else if v.enabled {
            supervisors[id]?.start()
        }
    }

    func chooseAndAddVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Vault"
        panel.message = "Choose an Obsidian vault folder to keep synced with Obsidian Headless."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { addVault(path: url.path) }
    }

    private func save() { ConfigStore.save(settings) }

    // MARK: - Controls

    func start(_ id: UUID) { userPaused.remove(id); supervisors[id]?.start() }
    func pause(_ id: UUID) { userPaused.insert(id); supervisors[id]?.stop(as: .paused) }
    func restart(_ id: UUID) { userPaused.remove(id); supervisors[id]?.restart() }
    func syncNow(_ id: UUID) { userPaused.remove(id); supervisors[id]?.syncNow() }
    func takeOver(_ id: UUID) { userPaused.remove(id); supervisors[id]?.takeOver() }

    func pauseAll() { settings.vaults.forEach { pause($0.id) } }
    func resumeAll() { settings.vaults.forEach { start($0.id) } }

    func isUserPaused(_ id: UUID) -> Bool { userPaused.contains(id) }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - Helpers surfaced in the menu

    func openFolder(_ v: VaultConfig) {
        NSWorkspace.shared.open(URL(fileURLWithPath: v.path))
    }

    func openInObsidian(_ v: VaultConfig) {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "vault", value: v.name)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Windows (plain NSWindows so nothing opens at launch)

    private var windows: [String: NSWindow] = [:]

    private func showWindow<V: View>(key: String, title: String, size: NSSize, content: () -> V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[key] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        windows[key] = w
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            self?.windows[key] = nil
        }
        w.makeKeyAndOrderFront(nil)
    }

    func vaultName(_ id: UUID) -> String {
        settings.vaults.first(where: { $0.id == id })?.name ?? "Vault"
    }

    func openLog(_ id: UUID) {
        showWindow(key: "log-\(id)", title: "Sync Log: \(vaultName(id))", size: NSSize(width: 760, height: 440)) {
            LogView(model: self, vaultID: id)
        }
    }

    /// Activity window: what's been uploaded, downloaded, merged, deleted.
    func openActivity(_ id: UUID? = nil) {
        showWindow(key: "activity", title: "Sync Activity", size: NSSize(width: 820, height: 520)) {
            ActivityView(model: self, activity: activity, initialVault: id)
        }
    }

    // MARK: - File helpers for activity rows

    func absolutePath(_ event: SyncEvent) -> String? {
        guard let v = settings.vaults.first(where: { $0.id == event.vaultID }) else { return nil }
        return (v.path as NSString).appendingPathComponent(event.path)
    }

    func reveal(_ event: SyncEvent) {
        guard let path = absolutePath(event) else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            // Deleted: open the containing folder if it still exists.
            let dir = (path as NSString).deletingLastPathComponent
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    func openInObsidian(_ event: SyncEvent) {
        guard let v = settings.vaults.first(where: { $0.id == event.vaultID }) else { return }
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "vault", value: v.name), URLQueryItem(name: "file", value: event.path)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    func copyPath(_ event: SyncEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(absolutePath(event) ?? event.path, forType: .string)
    }

    func revealLog(_ id: UUID) {
        if let url = supervisors[id]?.logger.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copyCommand(_ v: VaultConfig) {
        guard let ob = binaries?.ob else { return }
        var cmd = "\(Self.shellQuote(ob)) sync --path \(Self.shellQuote(v.path))"
        if v.continuous { cmd += " --continuous" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    func showStatus(_ id: UUID) {
        supervisors[id]?.refreshStatusText { text in
            let alert = NSAlert()
            alert.messageText = "ob sync-status"
            alert.informativeText = text.isEmpty ? "(no output)" : text
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Interactive steps handed to Terminal (login / setup need a TTY and secrets)

    func loginInTerminal() {
        guard let b = binaries else { return }
        runInTerminal(name: "ob-login", binaries: b, script: """
        OB=\(Self.shellQuote(b.ob))
        "$OB" login
        echo
        read -k 1 "?Done. Press any key to close, then choose Start in VaultWatch. "
        """)
    }

    func setupInTerminal(_ v: VaultConfig) {
        guard let b = binaries else { return }
        runInTerminal(name: "ob-sync-setup", binaries: b, script: """
        OB=\(Self.shellQuote(b.ob))
        echo "Back up your vault before the first sync."
        echo
        echo "Your remote vaults:"
        "$OB" sync-list-remote
        echo
        printf '%s' \(Self.shellQuote("Remote vault name or ID to link to \(v.name): "))
        read v
        "$OB" sync-setup --vault "$v" --path \(Self.shellQuote(v.path))
        echo
        read -k 1 "?Done. Press any key to close, then choose Start in VaultWatch. "
        """)
    }

    private func runInTerminal(name: String, binaries: ResolvedBinaries, script: String) {
        let dir = ConfigStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).command")
        let body = "#!/bin/zsh\nexport PATH=\(Self.shellQuote(binaries.childPath))\n\(script)\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)   // .command files open in Terminal
        } catch {
            NSLog("VaultWatch: could not write \(url.path): \(error)")
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
