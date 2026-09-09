import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Brings a specific window forward.
///
/// Three things make this harder than a single Accessibility call:
///
/// * `NSRunningApplication.activate()` is unreliable from an accessory app that is never itself
///   active, so activation goes through `kAXFrontmostAttribute`, which a trusted process may set.
/// * macOS only lists an application's windows through AX while they are on the active Space, and
///   some applications — Chrome in particular — never list them at all, answering only
///   `AXFocusedWindow`. For those the app's own ⌘` "cycle windows" shortcut is the only way to walk
///   to a specific window.
/// * Applications answer asynchronously, and an app that has just been activated will report the
///   wrong window for a moment. So focusing is a short retry loop rather than one call, and each
///   new request cancels the previous loop.
enum WindowFocuser {
    private static let maxAttempts = 20
    private static let retryInterval: TimeInterval = 0.1
    /// Attempt after which we stop waiting for the app to change Space on its own.
    private static let forceSpaceSwitchAttempt = 3

    /// Identifies the current focus request; an older loop sees a stale token and gives up.
    private static var generation: UInt64 = 0
    /// Remaining ⌘` presses allowed for the running request.
    private static var cyclePressBudget = 0

    /// The window a focus request is currently trying to reach.
    ///
    /// While this is set, incoming accessibility focus notifications for a *different* window are
    /// ignored, so that an app reporting its old window mid-transition cannot drag the queue's
    /// selection back with it.
    private(set) static var pendingTargetID: CGWindowID?

    /// - Parameters:
    ///   - workspaceIndex: 1-based workspace the window sits on, when known.
    ///   - siblingCount: how many windows the same application has, which bounds the ⌘` fallback.
    static func focus(_ window: ManagedWindow, workspaceIndex: Int? = nil, siblingCount: Int = 1) {
        generation &+= 1
        let token = generation
        pendingTargetID = window.id
        cyclePressBudget = max(0, siblingCount - 1) * 2

        if Diagnostics.isEnabled {
            Diagnostics.note("focus \(window.appName) id=\(window.id) element=\(window.element != nil) siblings=\(siblingCount)")
        }

        let appElement = AXUIElementCreateApplication(window.pid)
        if let element = window.element {
            raise(element, appElement: appElement, wasMinimized: window.isMinimized)
        } else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            appElement.setAttribute(kAXFrontmostAttribute, value: kCFBooleanTrue)
        }

        verify(window, workspaceIndex: workspaceIndex, token: token, attempt: 0)
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

    private static func finish(token: UInt64) {
        guard token == generation else { return }
        pendingTargetID = nil
        cyclePressBudget = 0
    }

    private static func verify(_ window: ManagedWindow, workspaceIndex: Int?,
                               token: UInt64, attempt: Int) {
        guard attempt < maxAttempts else {
            finish(token: token)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            // A newer request has taken over; stop competing with it.
            guard token == generation else { return }

            let appElement = AXUIElementCreateApplication(window.pid)
            let focusedID = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
                .flatMap { AXPrivate.windowID(of: $0) }

            if Diagnostics.isEnabled {
                let listed = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self)?.count ?? -1
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                Diagnostics.note("  verify #\(attempt) target=\(window.id) focused=\(focusedID.map(String.init) ?? "nil") axWindows=\(listed) front=\(front)")
            }
            if focusedID == window.id {
                finish(token: token)
                return
            }

            // Activating an app usually makes macOS follow it to its Space, but not every app
            // cooperates. Fall back to the system's own ⌃N shortcut. (The private SkyLight call
            // does move Spaces, but leaves the WindowServer drawing several desktops at once.)
            if attempt == forceSpaceSwitchAttempt,
               let index = workspaceIndex,
               let target = window.spaceID,
               SpacesBridge.shared.currentSpaceID != target {
                SpaceSwitcher.sendSystemShortcut(index: index)
            }

            if let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self),
               let match = windows.first(where: { AXPrivate.windowID(of: $0) == window.id }) {
                raise(match, appElement: appElement, wasMinimized: window.isMinimized)
            } else if attempt >= forceSpaceSwitchAttempt {
                cycleWindows(of: window, appElement: appElement)
            }

            verify(window, workspaceIndex: workspaceIndex, token: token, attempt: attempt + 1)
        }
    }

    /// Walks an application through its own windows with ⌘`.
    ///
    /// This is the only route to a window of an app that keeps `AXWindows` empty: there is no
    /// element to raise, but the app still responds to its standard cycle-windows shortcut. The
    /// verification loop stops the moment the focused window is ours, and the press budget bounds
    /// the cost for a window that cannot be reached this way.
    private static func cycleWindows(of window: ManagedWindow, appElement: AXUIElement) {
        guard cyclePressBudget > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        else { return }
        cyclePressBudget -= 1

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        if Diagnostics.isEnabled {
            Diagnostics.note("  cycle press for pid=\(window.pid) budget=\(cyclePressBudget)")
        }
    }
}
