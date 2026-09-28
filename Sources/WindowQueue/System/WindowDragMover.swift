import AppKit

/// Carries single windows to another workspace the way a person does: holding the window by its
/// title bar while the desktop changes.
///
/// macOS 26 turns down every WindowServer call that moves another process's window between spaces,
/// assigning the application moves all of its windows at once, and a minimized window is restored
/// to the desktop it came from. A window held down with the mouse, though, goes wherever the desktop
/// goes, whoever owns it. So the window's title bar is pressed and nudged, the carrier takes the
/// desktop to the target — it answers to no keyboard state, unlike `⌃N` pressed while the user is
/// still holding the shortcut that asked for this — and the window is let go on arrival.
///
/// The user travels along, which is what moving a window to a workspace does anyway.
enum WindowDragMover {
    /// A carry is under way: the pointer is ours until it ends, and nothing may act on where it is.
    private(set) static var isCarrying = false

    /// Carries the windows one after another to `target`. A window that does not make it leaves the
    /// user back on the desktop they started from rather than on one without it.
    /// - Parameter completion: the windows that arrived.
    static func carry(_ windows: [ManagedWindow], to target: UInt64,
                      completion: @escaping ([ManagedWindow]) -> Void) {
        guard !isCarrying, !windows.isEmpty else {
            completion([])
            return
        }
        isCarrying = true
        let origin = SpacesBridge.shared.currentSpaceID
        var remaining = windows
        var arrived: [ManagedWindow] = []

        func next() {
            guard !remaining.isEmpty else { return finish() }
            let window = remaining.removeFirst()
            carryOne(window, to: target) { ok in
                if ok { arrived.append(window) }
                next()
            }
        }

        func finish() {
            let end = { (_: Bool) in
                isCarrying = false
                completion(arrived)
            }
            guard arrived.isEmpty, let origin, origin != target else { return end(true) }
            travel(to: origin, then: end)
        }

        next()
    }

    private static func carryOne(_ window: ManagedWindow, to target: UInt64, done: @escaping (Bool) -> Void) {
        guard let space = SpacesBridge.shared.spaces(forWindows: [window.id])[window.id] else { return done(false) }
        if space == target { return done(true) }
        // The window has to be on screen to be held; one on another desktop is visited first.
        travel(to: space) { there in
            guard there else {
                Diagnostics.note("drag mover: could not reach \(window.appName) \(window.id) on space \(space)")
                return done(false)
            }
            // In front, so the point pressed is this window's title bar and nobody else's.
            WindowFocuser.bringToFront(pid: window.pid, windowID: window.id)
            (window.element ?? WindowSpaceMover.element(for: window))?.perform(kAXRaiseAction)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                hold(window, while: target, done: done)
            }
        }
    }

    private static func hold(_ window: ManagedWindow, while target: UInt64, done: @escaping (Bool) -> Void) {
        guard let frame = serverFrame(of: window.id) else { return done(false) }
        // Just inside the top edge: the title bar on every window with one, above a browser's
        // tabs, and clear of the buttons at either end.
        let grip = CGPoint(x: frame.midX, y: frame.minY + 5)
        guard topWindow(at: grip) == window.id else {
            Diagnostics.note("drag mover: \(window.appName) \(window.id) is not the window at its own title bar")
            return done(false)
        }
        let pointer = CGEvent(source: nil)?.location
        post(.mouseMoved, at: grip)
        post(.leftMouseDown, at: grip)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            // A press that has not moved is a click; the window only counts as held once dragged.
            let held = CGPoint(x: grip.x + 1, y: grip.y)
            post(.leftMouseDragged, at: held)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                travel(to: target) { _ in
                    post(.leftMouseUp, at: held)
                    if let pointer {
                        CGWarpMouseCursorPosition(pointer)
                        CGAssociateMouseAndMouseCursorPosition(1)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let now = SpacesBridge.shared.spaces(forWindows: [window.id])[window.id]
                        Diagnostics.note("drag mover: \(window.appName) \(window.id) "
                                         + (now == target ? "carried to \(target)" : "stayed on \(now.map(String.init) ?? "?")"))
                        done(now == target)
                    }
                }
            }
        }
    }

    /// Goes to a desktop and calls back once it is on show, or once it is clear it will not be.
    private static func travel(to space: UInt64, then: @escaping (Bool) -> Void) {
        if SpacesBridge.shared.isShowing(space) { return then(true) }
        guard SpaceSwitcher.jump(toSpace: space) else { return then(false) }
        wait(until: { SpacesBridge.shared.isShowing(space) }, timeout: 2.0) { arrived in
            // What is on show changes as the slide ends; letting go in that same instant can still
            // leave the window on the desktop being left.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { then(arrived) }
        }
    }

    private static func wait(until condition: @escaping () -> Bool, timeout: TimeInterval,
                             then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() { return then(true) }
            if Date() >= deadline { return then(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
        }
        check()
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                            mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        // The shortcut that asked for this may still be held; the press is a plain one all the same.
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }

    private static func serverFrame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The ordinary window in front at a point, in the same top-left coordinates as the frames.
    private static func topWindow(at point: CGPoint) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point)
            else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}
