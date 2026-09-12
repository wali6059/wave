import Foundation
import ServiceManagement
import WaveCore

/// Launch at login, via `SMAppService`.
///
/// `SMAppService.mainApp` is the modern replacement for the login-item
/// shenanigans of old, and it needs nothing beyond a properly signed bundle:
/// no helper target, no privileged install. It only works for an app that is
/// actually in a bundle, so an unbundled debug run reports unavailable rather
/// than pretending.
enum LaunchAtLogin {

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, which is not always what was asked for:
    /// macOS can leave the service in `requiresApproval` when the user has
    /// previously disabled it in System Settings.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard isAvailable else {
            Diagnostics.shared.warning("Login", "Launch at login needs Wave to be running from a signed .app bundle")
            return false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Diagnostics.shared.error("Login", "Could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }

        let status = SMAppService.mainApp.status
        if enabled && status == .requiresApproval {
            Diagnostics.shared.notice("Login", "macOS needs the login item approved in System Settings ▸ General ▸ Login Items")
        }
        return status == .enabled
    }

    static var requiresApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }
}
