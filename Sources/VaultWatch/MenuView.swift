import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VaultWatch").font(.headline)
                Spacer()
                Button {
                    model.openActivity()
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let help = model.binariesHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text(help).font(.caption).foregroundStyle(.red)
                    Button("Re-check") { model.recheckBinaries() }
                }
            }

            Divider()

            if model.settings.vaults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No vaults yet.").font(.subheadline.weight(.semibold))
                    Text("Import the vaults you set up with `ob sync-setup`, or add a folder.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Import from ob") { model.importConfiguredVaults() }
                }
            }

            ForEach(model.settings.vaults) { vault in
                VaultRow(
                    model: model,
                    vault: vault,
                    runtime: model.runtimes[vault.id] ?? VaultRuntime(),
                    recent: activity.events(for: vault.id, limit: 4),
                    today: activity.counts(for: vault.id, since: Calendar.current.startOfDay(for: Date()))
                )
                Divider()
            }

            HStack {
                Button("Add Vault…") { model.chooseAndAddVault() }
                Spacer()
                Menu {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    Toggle("Show Status Text in Menu Bar", isOn: $model.showMenuBarText)
                    Divider()
                    Button("Pause All") { model.pauseAll() }
                    Button("Resume All") { model.resumeAll() }
                    Divider()
                    Button("Import Vaults from ob") { model.importConfiguredVaults() }
                    Button("Log In to Obsidian (Terminal)…") { model.loginInTerminal() }
                    Divider()
                    Button("Open Logs Folder") { NSWorkspace.shared.open(VaultLogger.directory) }
                    Button("Open Config Folder") { NSWorkspace.shared.open(ConfigStore.directory) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct VaultRow: View {
    @ObservedObject var model: AppModel
    let vault: VaultConfig
    let runtime: VaultRuntime
    let recent: [SyncEvent]
    let today: (up: Int, down: Int, issues: Int)

    private var color: Color {
        switch runtime.phase {
        case .running: return .green
        case .syncing, .starting, .backoff: return .blue
        case .paused, .stopped: return .secondary
        case .needsSetup, .blocked: return .orange
        case .failed: return .red
        }
    }

    private var isTakeoverCase: Bool {
        runtime.phase == .blocked && runtime.detail.hasPrefix("Another")
    }

    /// One-line status: ob's live connection state when running, otherwise the phase.
    @ViewBuilder
    private var statusLine: some View {
        if runtime.phase == .running, runtime.connection != .unknown {
            HStack(spacing: 4) {
                Text(runtime.connection.label)
                if case .upToDate(let since) = runtime.connection {
                    Text("·").foregroundStyle(.secondary)
                    Text(since, style: .relative).foregroundStyle(.secondary)
                    Text("ago").foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        } else {
            Text(runtime.detail.isEmpty ? runtime.phase.label : "\(runtime.phase.label): \(runtime.detail)")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: runtime.phase.symbol).foregroundStyle(color)
                Text(vault.name).font(.subheadline.weight(.semibold))
                Spacer()
                if today.up + today.down > 0 {
                    Text("↑\(today.up) ↓\(today.down) today")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(vault.continuous ? "continuous" : "every \(vault.intervalMinutes) min")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            statusLine.font(.caption)

            if !runtime.warning.isEmpty {
                Text(runtime.warning)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(recent) { e in
                        Button {
                            model.reveal(e)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: e.kind.symbol)
                                    .foregroundStyle(ActivityView.color(e.kind))
                                    .frame(width: 14)
                                Text(e.kind == .error ? e.path : e.fileName)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(e.date, format: .dateTime.hour().minute())
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(e.kind.label): \(e.path)")
                    }
                    Button("Show All Activity…") { model.openActivity(vault.id) }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.top, 2)
            }

            HStack(spacing: 8) {
                actionButtons
                Spacer()
                moreMenu
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch runtime.phase {
        case .needsSetup:
            Button("Set Up in Terminal…") { model.setupInTerminal(vault) }
            Button("Log In…") { model.loginInTerminal() }
            Button("Retry") { model.start(vault.id) }
        case .blocked where isTakeoverCase:
            Button("Take Over") { model.takeOver(vault.id) }
            Button("Retry") { model.start(vault.id) }
        case .blocked:
            Button("Retry") { model.start(vault.id) }
        case .paused, .stopped:
            Button("Start") { model.start(vault.id) }
        case .failed:
            Button("Retry") { model.start(vault.id) }
            Button("View Log") { model.openLog(vault.id) }
        case .running, .syncing, .starting, .backoff:
            Button("Pause") { model.pause(vault.id) }
            Button("Sync Now") { model.syncNow(vault.id) }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Restart") { model.restart(vault.id) }
            Divider()
            Button("Activity…") { model.openActivity(vault.id) }
            Button("View Log") { model.openLog(vault.id) }
            Button("Reveal Log File") { model.revealLog(vault.id) }
            Button("Show Sync Status…") { model.showStatus(vault.id) }
            Divider()
            Button("Open Folder") { model.openFolder(vault) }
            Button("Open in Obsidian") { model.openInObsidian(vault) }
            Button("Copy Command") { model.copyCommand(vault) }
            Divider()
            Toggle("Continuous", isOn: Binding(
                get: { vault.continuous },
                set: { on in model.updateVault(vault.id) { $0.continuous = on } }
            ))
            if !vault.continuous {
                Picker("Interval", selection: Binding(
                    get: { vault.intervalMinutes },
                    set: { mins in model.updateVault(vault.id) { $0.intervalMinutes = mins } }
                )) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            Toggle("Start Automatically", isOn: Binding(
                get: { vault.enabled },
                set: { on in model.updateVault(vault.id) { $0.enabled = on } }
            ))
            Divider()
            Button("Set Up in Terminal…") { model.setupInTerminal(vault) }
            Divider()
            Button("Remove Vault", role: .destructive) { model.removeVault(vault.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
