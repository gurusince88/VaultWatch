import SwiftUI

final class LogViewModel: ObservableObject {
    @Published var lines: [String] = []
    private weak var logger: VaultLogger?

    func attach(_ logger: VaultLogger?) {
        self.logger = logger
        lines = logger?.snapshot() ?? []
        logger?.onLine = { [weak self] line in
            guard let self = self else { return }
            self.lines.append(line)
            if self.lines.count > VaultLogger.ringSize {
                self.lines.removeFirst(self.lines.count - VaultLogger.ringSize)
            }
        }
    }

    func detach() {
        logger?.onLine = nil
    }
}

struct LogView: View {
    @ObservedObject var model: AppModel
    let vaultID: UUID
    @StateObject private var vm = LogViewModel()

    private var vaultName: String {
        model.settings.vaults.first(where: { $0.id == vaultID })?.name ?? "Vault"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(vm.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: vm.lines.count) { _ in
                if let last = vm.lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear { vm.attach(model.logger(for: vaultID)) }
        .onDisappear { vm.detach() }
    }
}
