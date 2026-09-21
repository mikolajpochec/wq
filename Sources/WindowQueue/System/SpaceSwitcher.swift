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
            return "Activates the first queued window on the target workspace, which makes macOS animate to it. Falls back to the ⌃N shortcut for workspaces with no windows."
        case .systemShortcut:
            return "Requires “Switch to Desktop N” to be enabled in System Settings › Keyboard › Keyboard Shortcuts › Mission Control."
        case .privateAPI:
            return "Switches instantly with no animation. Not recommended: on current macOS the WindowServer is left drawing several desktops at once until Mission Control redraws them."
        }
    }
}

enum SpaceSwitcher {
    /// Goes to a workspace that has no windows to focus, by putting a window of our own there.
    ///
    /// A process may place its *own* windows on any space, and activating an application makes macOS
    /// animate to a space where one of its windows is. So a one-pixel transparent panel, moved onto
    /// the target workspace and brought forward, is a workspace switch — animation included, and
    /// without the `⌃N` shortcut, which the user has to have enabled for desktops 5 and up.
    ///
    /// The panel is ordered out again straight away, and WindowQueue steps back so the workspace is
    /// left the way arriving there by hand leaves it.
    /// - Parameter arrived: called once the switch has been set off, in place of stepping back —
    ///   whoever is being focused there takes over from the carrier.
    @discardableResult
    static func jump(toSpace spaceID: UInt64, then arrived: (() -> Void)? = nil) -> Bool {
        guard let addWindows, let removeWindows, connectionID != 0 else { return false }
        let panel = carrier
        panel.orderFront(nil)
        guard panel.windowNumber > 0 else { return false }

        let windows = [NSNumber(value: panel.windowNumber)] as CFArray
        addWindows(connectionID, windows, [NSNumber(value: spaceID)] as CFArray)
        if let current = SpacesBridge.shared.currentSpaceID, current != spaceID {
            removeWindows(connectionID, windows, [NSNumber(value: current)] as CFArray)
        }

        // The WindowServer needs the window to be on the target space before the activation, and an
        // accessory app has to ask for activation explicitly to be followed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if let arrived {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    arrived()
                    panel.orderOut(nil)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                panel.orderOut(nil)
                NSApp.deactivate()
            }
        }
        Diagnostics.note("space jump: carrier window to space \(spaceID)")
        return true
    }

    private static let carrier: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.nonactivatingPanel, .titled],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.hasShadow = false
        panel.level = .normal
        // No collection behaviour at all: `.stationary` in particular keeps the WindowServer from
        // treating the window as a reason to change space, which is the whole point of it.
        panel.animationBehavior = .none
        return panel
    }()

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias WindowsSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let connectionID = symbol("CGSMainConnectionID", as: ConnectionFn.self)?() ?? 0
    private static let addWindows = symbol("CGSAddWindowsToSpaces", as: WindowsSpacesFn.self)
    private static let removeWindows = symbol("CGSRemoveWindowsFromSpaces", as: WindowsSpacesFn.self)

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
