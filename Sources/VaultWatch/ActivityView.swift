import SwiftUI

/// Window listing every file VaultWatch has seen `ob` upload, download, merge, or delete.
struct ActivityView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var activity: ActivityStore

    @State private var vaultFilter: UUID?
    @State private var kindFilter: KindFilter = .all
    @State private var search = ""
    @State private var selection = Set<SyncEvent.ID>()

    init(model: AppModel, activity: ActivityStore, initialVault: UUID?) {
        self.model = model
        self.activity = activity
        _vaultFilter = State(initialValue: initialVault)
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", uploads = "Uploads", downloads = "Downloads", deletes = "Deletes", issues = "Issues"
        var id: String { rawValue }

        func matches(_ kind: SyncEventKind) -> Bool {
            switch self {
            case .all: return true
            case .uploads: return kind == .upload
            case .downloads: return kind == .download
            case .deletes: return kind == .deleteLocal || kind == .deleteRemote
            case .issues: return kind.isIssue
            }
        }
    }

    private var filtered: [SyncEvent] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return activity.events.filter { e in
            (vaultFilter == nil || e.vaultID == vaultFilter)
                && kindFilter.matches(e.kind)
                && (q.isEmpty || e.path.lowercased().contains(q))
        }
    }

    private var todayCounts: (up: Int, down: Int, issues: Int) {
        let start = Calendar.current.startOfDay(for: Date())
        var up = 0, down = 0, issues = 0
        for e in activity.events where vaultFilter == nil || e.vaultID == vaultFilter {
            if e.date < start { break }
            if e.kind == .upload { up += 1 } else if e.kind == .download { down += 1 } else if e.kind.isIssue { issues += 1 }
        }
        return (up, down, issues)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)

            if model.settings.vaults.count > 1 {
                Picker("Vault", selection: $vaultFilter) {
                    Text("All Vaults").tag(UUID?.none)
                    ForEach(model.settings.vaults) { v in
                        Text(v.name).tag(UUID?.some(v.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            Spacer()

            TextField("Filter by file name", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(10)
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("") { e in
                Image(systemName: e.kind.symbol)
                    .foregroundStyle(Self.color(e.kind))
            }
            .width(22)

            TableColumn("File") { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.kind == .error ? e.path : e.fileName).lineLimit(1)
                    if e.kind != .error {
                        Text(e.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(e.path)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Action") { e in Text(e.kind.label) }
                .width(min: 90, ideal: 120)

            TableColumn("Vault") { e in Text(model.vaultName(e.vaultID)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 120)

            TableColumn("When") { e in
                Text(Self.whenText(e.date))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: SyncEvent.ID.self) { ids in
            if let e = event(for: ids) {
                Button("Reveal in Finder") { model.reveal(e) }
                Button("Open in Obsidian") { model.openInObsidian(e) }
                    .disabled(e.kind == .deleteLocal || e.kind == .deleteRemote || e.kind == .error)
                Button("Copy Path") { model.copyPath(e) }
            }
        } primaryAction: { ids in
            if let e = event(for: ids) { model.reveal(e) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(activity.events.isEmpty ? "No sync activity yet" : "Nothing matches this filter")
                .font(.headline)
            Text("Files appear here as ob uploads, downloads, merges, or deletes them.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        let c = todayCounts
        return HStack(spacing: 14) {
            Text("Today:").foregroundStyle(.secondary)
            Label("\(c.up) uploaded", systemImage: "arrow.up")
            Label("\(c.down) downloaded", systemImage: "arrow.down")
            if c.issues > 0 {
                Label("\(c.issues) need attention", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(filtered.count) of \(activity.events.count) events").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func event(for ids: Set<SyncEvent.ID>) -> SyncEvent? {
        guard let id = ids.first else { return nil }
        return activity.events.first(where: { $0.id == id })
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d jj:mm")
        return f
    }()

    static func whenText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? timeFormatter.string(from: date)
            : dayTimeFormatter.string(from: date)
    }

    static func color(_ kind: SyncEventKind) -> Color {
        switch kind {
        case .upload: return .blue
        case .download: return .green
        case .deleteLocal, .deleteRemote: return .secondary
        case .merge: return .purple
        case .conflict, .skipped: return .orange
        case .error: return .red
        }
    }
}
