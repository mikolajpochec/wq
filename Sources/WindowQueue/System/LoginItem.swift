import Foundation
import ServiceManagement

/// Starts WindowQueue when the user logs in, through the system's own login-item registry, so it
/// shows up — and can be switched off — in the system's login item settings like any other app.
enum LoginItem {
    enum State {
        case enabled
        case disabled
        /// The system wants the user to confirm it in the login item settings first.
        case needsApproval
        /// Running from somewhere other than the Applications folder, e.g. a build directory.
        /// Registering that copy would start a stale build at login and break on the next rebuild.
        case notInstalled
    }

    static var isInstalled: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static var state: State {
        guard isInstalled else { return .notInstalled }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .disabled
        }
    }

    /// Brings the registration in line with the preference. Idempotent, so it is safe to call on
    /// every launch and on every settings change.
    static func apply(enabled: Bool) {
        guard isInstalled else { return }
        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                return
            case (true, _):
                try service.register()
            case (false, _):
                try service.unregister()
            }
        } catch {
            if Diagnostics.isEnabled {
                Diagnostics.note("login item \(enabled ? "register" : "unregister") failed: \(error)")
            }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
