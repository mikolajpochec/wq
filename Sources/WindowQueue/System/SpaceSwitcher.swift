import AppKit
import Carbon.HIToolbox

/// Ways to change the active Mission Control workspace, none of which macOS offers publicly.
enum SpaceSwitchMethod: String, Codable, CaseIterable, Identifiable {
    /// Focus a window that already lives on the target workspace and let macOS follow it.
    case focusWindow
    /// Synthesise the built-in ⌃1…⌃9 Mission Control shortcut.
    case systemShortcut
    /// Ask the WindowServer directly through the private SkyLight API.
    case privateAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusWindow: return "Focus a window on that workspace (recommended)"
        case .systemShortcut: return "Send macOS ⌃1…⌃9 shortcut"
        case .privateAPI: return "Private SkyLight API"
        }
    }

    var explanation: String {
        switch self {
        case .focusWindow:
            return "Activates the first queued window on the target workspace, which makes macOS animate to it. Falls back to the ⌃N shortcut, then the private API, for empty workspaces."
        case .systemShortcut:
            return "Requires “Switch to Desktop N” to be enabled in System Settings › Keyboard › Keyboard Shortcuts › Mission Control."
        case .privateAPI:
            return "Switches instantly with no animation. Undocumented, and some macOS versions leave the desktop in an odd state."
        }
    }
}

enum SpaceSwitcher {
    private static let digitKeyCodes: [CGKeyCode] = [
        CGKeyCode(kVK_ANSI_1), CGKeyCode(kVK_ANSI_2), CGKeyCode(kVK_ANSI_3),
        CGKeyCode(kVK_ANSI_4), CGKeyCode(kVK_ANSI_5), CGKeyCode(kVK_ANSI_6),
        CGKeyCode(kVK_ANSI_7), CGKeyCode(kVK_ANSI_8), CGKeyCode(kVK_ANSI_9),
    ]

    /// Posts the system-wide ⌃N Mission Control shortcut for the 1-based workspace index.
    @discardableResult
    static func sendSystemShortcut(index: Int) -> Bool {
        guard digitKeyCodes.indices.contains(index - 1) else { return false }
        let key = digitKeyCodes[index - 1]
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
