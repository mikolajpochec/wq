import AppKit

/// Bringing WindowQueue's own windows — Settings, the tour — to the front.
///
/// The app lives in the menu bar, so it has to turn into a regular app first, and macOS may turn
/// down the activation that follows (it is only a request since macOS 14, and the policy change
/// lands a moment later); the window then opens under the app in front. And hover focus, seeing
/// the pointer still resting where the menu was, would hand the keyboard straight back to the
/// window under it.
enum OwnWindows {
    private static var presentedAt = Date.distantPast
    private static var pointerAtPresent = NSPoint.zero

    static func present(_ window: NSWindow) {
        presentedAt = Date()
        pointerAtPresent = NSEvent.mouseLocation
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Once the policy change has landed: if the activation was declined, go through the
        // WindowServer the way a click on the window would — the path used for other apps' windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard window.isVisible else { return }
            if !NSApp.isActive || !window.isKeyWindow {
                Diagnostics.note("own window \(window.windowNumber) not in front after activation; fronting it")
                WindowFocuser.bringToFront(pid: getpid(), windowID: CGWindowID(window.windowNumber))
                NSApp.activate()
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The same for a modal alert about to `runModal()`, which blocks: the checks run on timers in
    /// the modal run loop mode. The app stays an accessory (no Dock icon for a small prompt), so
    /// the activation is often declined while another app is in front (always so while aiming,
    /// whose keys come through an event tap rather than as events of ours), and the alert then
    /// opens without the keyboard; the WindowServer path makes it key, with the caret in `field`.
    static func presentModal(_ window: NSWindow, focusing field: NSView?) {
        presentedAt = Date()
        pointerAtPresent = NSEvent.mouseLocation
        NSApp.activate(ignoringOtherApps: true)
        for delay in [0.05, 0.2, 0.45] {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                guard window.isVisible else { return }
                if !NSApp.isActive || !window.isKeyWindow {
                    Diagnostics.note("alert \(window.windowNumber) not key after \(delay)s; fronting it")
                    _ = WindowFocuser.bringToFront(pid: getpid(), windowID: CGWindowID(window.windowNumber))
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                // While a text field is edited, the window's first responder is its field editor.
                let editing = (window.firstResponder as? NSText)?.delegate as AnyObject?
                if let field, window.firstResponder !== field, editing !== field {
                    window.makeFirstResponder(field)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
    }

    /// One of our windows has just opened and the pointer hasn't gone anywhere since: whatever is
    /// under it was not chosen, so hover focus leaves the new window be.
    static var justPresented: Bool {
        let location = NSEvent.mouseLocation
        let moved = hypot(location.x - pointerAtPresent.x, location.y - pointerAtPresent.y)
        return Date().timeIntervalSince(presentedAt) < 3 && moved < 40
    }
}
