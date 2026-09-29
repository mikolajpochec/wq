import AppKit
import Carbon.HIToolbox

/// Ways to change the active Mission Control workspace, none of which macOS offers publicly.
enum SpaceSwitchMethod: String, Codable, CaseIterable, Identifiable {
    /// Focus a window that already lives on the target workspace and let macOS follow it.
    case focusWindow
    /// Synthesise the built-in ⌃1…⌃9 Mission Control shortcut.
    case systemShortcut
    /// Carry a window of our own to the workspace through SkyLight and bring it forward, which the
    /// Dock follows. The name is from when this asked the WindowServer to switch outright; it stays
    /// so saved settings still read.
    case privateAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusWindow: return "Focus a window on that workspace (recommended)"
        case .systemShortcut: return "Send macOS ⌃1…⌃9 shortcut"
        case .privateAPI: return "Carry an invisible window there"
        }
    }

    var explanation: String {
        switch self {
        case .focusWindow:
            return "Activates the first queued window on the target workspace, which makes macOS animate to it. Workspaces with no windows are reached by carrying an invisible window there."
        case .systemShortcut:
            return "Requires “Switch to Desktop N” to be enabled in System Settings › Keyboard › Keyboard Shortcuts › Mission Control."
        case .privateAPI:
            return "Moves an invisible window of WindowQueue's to that workspace and brings it forward, so macOS animates there. Works for empty workspaces and past ⌃9."
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
    ///
    /// Only the latest jump counts: one asked for while another is still on its way takes over, and
    /// the earlier one neither activates nor calls back. There is a single carrier, so two jumps
    /// running side by side would leave it on two workspaces and macOS free to pick either.
    /// - Parameter arrived: called once the switch has been set off, in place of stepping back —
    ///   whoever is being focused there takes over from the carrier.
    @discardableResult
    static func jump(toSpace spaceID: UInt64, then arrived: (() -> Void)? = nil) -> Bool {
        guard let addWindows, let removeWindows, connectionID != 0 else { return false }
        let panel = carrier
        // On the target's own monitor: a desktop of another display is not where a window sitting
        // on this one can be brought forward.
        if let screen = SpacesBridge.shared.screen(ofSpace: spaceID) {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
        panel.orderFront(nil)
        guard panel.windowNumber > 0 else { return false }

        generation &+= 1
        let token = generation
        heading = (spaceID, Date().addingTimeInterval(headingLifetime))

        // The carrier keeps every space it was ever put on — ordering it out does not take it off
        // them — so whatever it is on besides the target goes, not just the desktop in view. The
        // desktops on show are named outright: the one it was just ordered in on may not be listed
        // for it yet, and a carrier left there too gives macOS no reason to go anywhere.
        let windows = [NSNumber(value: panel.windowNumber)] as CFArray
        let bridge = SpacesBridge.shared
        let stale = Set(bridge.allSpaces(forWindow: CGWindowID(panel.windowNumber)))
            .union(bridge.spacesOnShow)
            .subtracting([spaceID])
        addWindows(connectionID, windows, [NSNumber(value: spaceID)] as CFArray)
        if !stale.isEmpty {
            removeWindows(connectionID, windows, stale.map { NSNumber(value: $0) } as CFArray)
        }

        // The WindowServer needs the window to be on the target space before the activation, and an
        // accessory app has to ask for activation explicitly to be followed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard token == generation else { return }
            if Diagnostics.isEnabled {
                let on = SpacesBridge.shared.allSpaces(forWindow: CGWindowID(panel.windowNumber))
                Diagnostics.note("space jump: carrier on \(on) at activation, active=\(NSApp.isActive)")
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            // The request above is only a request, and none at all while WindowQueue is already in
            // front — as it is when this jump took over from one that had not stepped back yet.
            WindowFocuser.bringToFront(pid: getpid(), windowID: CGWindowID(panel.windowNumber))
            if let arrived {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard token == generation else { return }
                    arrived()
                    panel.orderOut(nil)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard token == generation else { return }
                panel.orderOut(nil)
                NSApp.deactivate()
            }
        }
        Diagnostics.note("space jump: carrier window to space \(spaceID)")
        return true
    }

    /// The workspace a jump is on its way to, while it may still be travelling. What is on show can
    /// lag behind for the length of the animation, so "is this window here already?" has to be
    /// answered against where we are going, not where we still are.
    static var destination: UInt64? {
        guard let heading, Date() < heading.until else { return nil }
        if SpacesBridge.shared.isShowing(heading.space) {
            self.heading = nil
            return nil
        }
        return heading.space
    }

    private static var generation: UInt64 = 0
    private static var heading: (space: UInt64, until: Date)?
    /// Long enough for the activation delay and the slide between desktops.
    private static let headingLifetime: TimeInterval = 1.2

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
