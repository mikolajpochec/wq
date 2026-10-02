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

    /// One of our windows has just opened and the pointer hasn't gone anywhere since: whatever is
    /// under it was not chosen, so hover focus leaves the new window be.
    static var justPresented: Bool {
        let location = NSEvent.mouseLocation
        let moved = hypot(location.x - pointerAtPresent.x, location.y - pointerAtPresent.y)
        return Date().timeIntervalSince(presentedAt) < 3 && moved < 40
    }
}
