import AppKit
import ApplicationServices

enum WindowFocuser {
    /// Raises a window and makes it the frontmost window of the frontmost app.
    ///
    /// `NSRunningApplication.activate()` alone is unreliable from an accessory app that is never
    /// itself active, so activation goes through `kAXFrontmostAttribute`, which a trusted process
    /// may set regardless of who is active.
    ///
    /// A window on another Space has no accessibility element yet, because macOS only lists an
    /// app's windows while they are on the active Space. Activating the app switches to it, after
    /// which the element can be resolved and the right window raised.
    static func focus(_ window: ManagedWindow) {
        let appElement = AXUIElementCreateApplication(window.pid)

        guard let element = window.element else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            appElement.setAttribute(kAXFrontmostAttribute, value: kCFBooleanTrue)
            retryAfterActivation(window)
            return
        }

        raise(element, appElement: appElement, wasMinimized: window.isMinimized)
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

    /// Once the Space transition has happened the window becomes visible to AX; raise it then so
    /// the right window of a multi-window app ends up in front.
    private static func retryAfterActivation(_ window: ManagedWindow, attempt: Int = 0) {
        guard attempt < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let appElement = AXUIElementCreateApplication(window.pid)
            guard let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self),
                  let match = windows.first(where: { AXPrivate.windowID(of: $0) == window.id })
            else {
                retryAfterActivation(window, attempt: attempt + 1)
                return
            }
            raise(match, appElement: appElement, wasMinimized: window.isMinimized)
        }
    }
}
