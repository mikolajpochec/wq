import AppKit
import ApplicationServices

/// Carries windows of other apps onto one workspace.
///
/// macOS 26 ignores `SLSMoveWindowsToManagedSpace` for windows another process owns, so there is no
/// API left for this. What still works is what a person would do: hold the window by its title bar
/// and switch workspace — the held window comes along. This does exactly that with synthesized
/// events, one window at a time, then puts the pointer back. It takes the mouse over for about a
/// second per window.
final class WindowSpaceMover {
    private let queue = DispatchQueue(label: "com.mpochec.windowqueue.space-mover")
    private(set) var isRunning = false

    /// Moves `windows` onto the workspace with the 1-based `index` (1…9, the range the system
    /// shortcuts cover), then calls back on the main queue with each window's fresh accessibility
    /// element, for the ones that could be found there.
    func move(_ windows: [ManagedWindow], toWorkspace index: Int, targetSpace: UInt64,
              focus: @escaping (ManagedWindow) -> Void,
              completion: @escaping ([ManagedWindow]) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        let origin = CGEvent(source: nil)?.location

        queue.async { [self] in
            for window in windows {
                let space = SpacesBridge.shared.spaces(forWindows: [window.id])[window.id]
                guard space != targetSpace else { continue }
                carry(window, toWorkspace: index, targetSpace: targetSpace, focus: focus)
            }

            // Finish on the target workspace, whichever window went last.
            if SpacesBridge.shared.currentSpaceID != targetSpace {
                SpaceSwitcher.sendSystemShortcut(index: index)
                waitFor(timeout: 1.5) { SpacesBridge.shared.currentSpaceID == targetSpace }
            }
            if let origin { CGWarpMouseCursorPosition(origin) }
            usleep(150_000)

            let refreshed = windows.map { window -> ManagedWindow in
                var copy = window
                copy.element = Self.element(for: window) ?? window.element
                copy.spaceID = SpacesBridge.shared.spaces(forWindows: [window.id])[window.id] ?? window.spaceID
                return copy
            }
            DispatchQueue.main.async {
                self.isRunning = false
                completion(refreshed)
            }
        }
    }

    private func carry(_ window: ManagedWindow, toWorkspace index: Int, targetSpace: UInt64,
                       focus: @escaping (ManagedWindow) -> Void) {
        // Go to the window first: it can only be picked up where it is.
        DispatchQueue.main.sync { focus(window) }
        let arrived = waitFor(timeout: 2.5) {
            SpacesBridge.shared.spaces(forWindows: [window.id])[window.id] == SpacesBridge.shared.currentSpaceID
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        }
        guard arrived, let element = Self.element(for: window), let frame = Self.frame(of: element) else {
            Diagnostics.note("space mover: could not reach \(window.appName) id=\(window.id)")
            return
        }
        // Let the focus request settle first: its own checks would otherwise switch back to the
        // window's old workspace while it is being carried away.
        usleep(600_000)

        // Just inside the top edge, in the middle: the title bar of an ordinary window, and the
        // strip above the tabs in a browser, rather than a tab that would tear off.
        let grab = CGPoint(x: frame.midX, y: frame.minY + 5)
        post(.leftMouseDown, at: grab)
        usleep(80_000)
        // A few pixels of travel turns the press into a window drag.
        for step in 1...4 {
            post(.leftMouseDragged, at: CGPoint(x: grab.x + CGFloat(step), y: grab.y))
            usleep(20_000)
        }
        usleep(120_000)
        SpaceSwitcher.sendSystemShortcut(index: index)
        let moved = waitFor(timeout: 1.5) { SpacesBridge.shared.currentSpaceID == targetSpace }
        usleep(350_000)
        post(.leftMouseUp, at: CGPoint(x: grab.x + 4, y: grab.y))
        usleep(200_000)

        let landed = SpacesBridge.shared.spaces(forWindows: [window.id])[window.id] == targetSpace
        Diagnostics.note("space mover: \(window.appName) id=\(window.id) switched=\(moved) landed=\(landed)")
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    private static func element(for window: ManagedWindow) -> AXUIElement? {
        AXPrivate.application(window.pid)
            .attribute(kAXWindowsAttribute, as: [AXUIElement].self)?
            .first { AXPrivate.windowID(of: $0) == window.id }
    }

    /// Frame in accessibility coordinates: top left of the menu bar screen, y downwards.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = element.attribute(kAXPositionAttribute, as: AXValue.self),
              let sizeRef = element.attribute(kAXSizeAttribute, as: AXValue.self)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef, .cgPoint, &position),
              AXValueGetValue(sizeRef, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}
