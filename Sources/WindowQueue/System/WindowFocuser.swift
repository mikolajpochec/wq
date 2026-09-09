import AppKit
import ApplicationServices

enum WindowFocuser {
    private static let maxAttempts = 20
    private static let retryInterval: TimeInterval = 0.1

    /// Raises a window and makes it the frontmost window of the frontmost app.
    ///
    /// Two things make this harder than one AX call. `NSRunningApplication.activate()` is unreliable
    /// from an accessory app that is never itself active, so activation goes through
    /// `kAXFrontmostAttribute`, which a trusted process may set regardless of who is active. And a
    /// window on another Space has no accessibility element yet, because macOS only lists an app's
    /// windows while they are on the active Space — activating the app moves to that Space, after
    /// which the element resolves and the *correct* window (not merely the app's front one) can be
    /// raised. So every focus ends with a verification loop that re-raises until the app reports
    /// our window as its focused one.
    /// - Parameter workspaceIndex: 1-based workspace the window sits on, when known. Used to move
    ///   Spaces if the app does not take us there itself.
    static func focus(_ window: ManagedWindow, workspaceIndex: Int? = nil) {
        let appElement = AXUIElementCreateApplication(window.pid)

        if let element = window.element {
            raise(element, appElement: appElement, wasMinimized: window.isMinimized)
        } else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            appElement.setAttribute(kAXFrontmostAttribute, value: kCFBooleanTrue)
        }

        verify(window, workspaceIndex: workspaceIndex, attempt: 0)
    }

    private static func raise(_ element: AXUIElement, appElement: AXUIElement, wasMinimized: Bool) {
        if wasMinimized {
            element.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
        }
        element.setAttribute(kAXMainAttribute, value: kCFBooleanTrue)
        element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
        element.perform(kAXRaiseAction)
        appElement.setAttribute(kAXFocusedWindowAttribute, value: element)
        appElement.setAttribute(kAXFrontmostAttribute, value: kCFBooleanTrue)
    }

    /// Attempt after which we stop waiting for the app to move Spaces on its own.
    private static let forceSpaceSwitchAttempt = 3

    /// Keeps re-raising until the app reports our window as focused. A Space transition takes a
    /// moment and the target window is invisible to AX until it completes, which is why a single
    /// attempt lands on whichever window of that app happened to be in front.
    ///
    /// Activating an app usually makes macOS follow it to its Space, but not every app cooperates —
    /// Chrome, for instance, just raises whichever of its windows is already here. When the Space
    /// still has not changed after a few attempts, send the system's own ⌃N shortcut. (Moving the
    /// Space through the private SkyLight call instead leaves the WindowServer showing several
    /// desktops at once on current macOS, so it is deliberately not used here.)
    private static func verify(_ window: ManagedWindow, workspaceIndex: Int?, attempt: Int) {
        guard attempt < maxAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            let appElement = AXUIElementCreateApplication(window.pid)

            if attempt == forceSpaceSwitchAttempt,
               let index = workspaceIndex,
               let target = window.spaceID,
               SpacesBridge.shared.currentSpaceID != target {
                SpaceSwitcher.sendSystemShortcut(index: index)
            }

            if let focused = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self),
               AXPrivate.windowID(of: focused) == window.id {
                return
            }

            guard let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self),
                  let match = windows.first(where: { AXPrivate.windowID(of: $0) == window.id })
            else {
                verify(window, workspaceIndex: workspaceIndex, attempt: attempt + 1)
                return
            }

            raise(match, appElement: appElement, wasMinimized: window.isMinimized)
            verify(window, workspaceIndex: workspaceIndex, attempt: attempt + 1)
        }
    }
}
