import AppKit
import Carbon.HIToolbox

/// The finder opened by the launcher shortcut. Spotlight is on every Mac; the others are only
/// worth choosing when they are installed, which the settings list says.
enum LauncherApp: String, Codable, CaseIterable, Identifiable {
    case spotlight, raycast, alfred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotlight: return "Spotlight"
        case .raycast: return "Raycast"
        case .alfred: return "Alfred"
        }
    }

    /// Where the app lives, for telling the user whether the choice will work.
    var applicationURL: URL? {
        switch self {
        case .spotlight: return nil
        case .raycast: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos")
        case .alfred: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.runningwithcrayons.Alfred")
        }
    }

    var isAvailable: Bool { self == .spotlight || applicationURL != nil }
}

/// Opening the things macOS has no API for: the launcher and Mission Control.
enum SystemLaunchers {
    /// Opens the chosen launcher, falling back to Spotlight when the app is not installed.
    static func open(_ launcher: LauncherApp) {
        switch launcher {
        case .spotlight:
            openSpotlight()
        case .raycast, .alfred:
            guard let url = launcher.applicationURL else {
                Diagnostics.note("launcher \(launcher.rawValue) is not installed, opening Spotlight")
                openSpotlight()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    Diagnostics.note("launcher \(launcher.rawValue) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    static let defaultRaycastCommand = "raycast://extensions/mikolaj_pochec/app-windows/open-app"

    /// Runs a Raycast command through its deeplink (`raycast://extensions/<author>/<extension>/<command>`).
    static func openRaycastCommand(_ deeplink: String) {
        let trimmed = deeplink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "raycast" else {
            Diagnostics.note("raycast command \"\(deeplink)\" is not a raycast:// link, opening the launcher")
            open(.raycast)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Mission Control is an app, so it opens like one — no key press to synthesize.
    static func showMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Diagnostics.note("Mission Control failed: \(error.localizedDescription)") }
        }
    }

    /// Spotlight has neither a URL scheme nor an app to open: its own shortcut is the only door,
    /// so that key press is posted. Whatever the user has bound it to, `⌘Space` is what Spotlight
    /// ships with, and a changed binding is why the setting offers the other launchers.
    private static func openSpotlight() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let key = CGKeyCode(kVK_Space)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
