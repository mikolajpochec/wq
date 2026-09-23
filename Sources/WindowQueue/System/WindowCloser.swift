import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Closes a window without the user having to switch to it first.
///
/// The Accessibility API models a title bar's close button as a pressable element, which is the
/// cleanest way to close one specific window. A window on another Space has no element yet, so it
/// has to be focused first and closed once it becomes reachable.
enum WindowCloser {
    private static let maxAttempts = 12
    private static let retryInterval: TimeInterval = 0.12

    static func close(_ window: ManagedWindow, workspaceIndex: Int?, siblingCount: Int) {
        if press(closeButton(of: window.element)) { return }

        WindowFocuser.focus(window, workspaceIndex: workspaceIndex, siblingCount: siblingCount)
        retry(window, siblingCount: siblingCount, attempt: 0)
    }

    private static func closeButton(of element: AXUIElement?) -> AXUIElement? {
        element?.attribute(kAXCloseButtonAttribute, as: AXUIElement.self)
    }

    private static func press(_ button: AXUIElement?) -> Bool {
        guard let button else { return false }
        return button.perform(kAXPressAction)
    }

    private static func retry(_ window: ManagedWindow, siblingCount: Int, attempt: Int) {
        guard attempt < maxAttempts else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            let appElement = AXPrivate.application(window.pid)

            if let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self),
               let match = windows.first(where: { AXPrivate.windowID(of: $0) == window.id }),
               press(closeButton(of: match)) {
                return
            }

            // An app that never exposes its windows (Chrome, Spotify) leaves only its own shortcut.
            // By now the focus attempt has had time to bring the right window forward — but ⌘W
            // closes whichever window has the keyboard, so only when that is known to be this one,
            // or the app has no other window it could be.
            if attempt == maxAttempts - 1,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid {
                let focused = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
                    .flatMap(AXPrivate.windowID(of:))
                if focused == window.id || (focused == nil && siblingCount <= 1) {
                    sendCloseShortcut()
                } else {
                    Diagnostics.note("close \(window.id): \(window.appName) has another window focused; not sending ⌘W")
                }
                return
            }

            retry(window, siblingCount: siblingCount, attempt: attempt + 1)
        }
    }

    private static func sendCloseShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
