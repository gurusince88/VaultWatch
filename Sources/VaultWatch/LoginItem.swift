import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (shows up in System Settings > General > Login Items).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("VaultWatch: login item change failed: \(error)")
            return false
        }
    }
}
