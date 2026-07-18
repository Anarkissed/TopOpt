// LoginItem — "Launch at Login" via SMAppService (macOS 13+), so the worker
// survives reboots without the user thinking about it (handoff 097, set-and-forget).

import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("TopOpt Worker: launch-at-login toggle failed: %@", error.localizedDescription)
        }
    }
}
