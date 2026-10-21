import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touch the model immediately so sync starts at login, before the menu is ever opened.
        _ = AppModel.shared

        // `kill`/`pkill` sends SIGTERM, which would otherwise skip applicationWillTerminate
        // and orphan the `ob` child. Route it through a normal quit instead.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigtermSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        // SIGTERM each `ob`, wait for a clean exit, SIGKILL only as a last resort.
        AppModel.shared.shutdownAll()
    }
}

@main
struct VaultWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, activity: model.activity)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.menuBarSymbol)
                if model.showMenuBarText {
                    Text(model.menuBarText)
                }
            }
        }
        .menuBarExtraStyle(.window)
        // Log windows are plain NSWindows opened by AppModel.openLog, so no empty
        // WindowGroup window appears at launch.
    }
}
