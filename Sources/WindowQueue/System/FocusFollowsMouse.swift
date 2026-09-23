import AppKit

/// Focuses the window under the pointer once the pointer comes to rest over it.
///
/// macOS has no focus without raising, so this is the raising flavour of focus-follows-mouse. It
/// waits for the pointer to settle, so crossing a stack of windows on the way somewhere does not
/// raise each one, and it stays out of the way whenever the pointer is over something that is not
/// an ordinary window — the strip, the menu bar, the Dock, a popup — or a menu is open.
final class FocusFollowsMouse {
    private let model: WindowQueueModel
    private let store: PreferencesStore
    private let focus: (ManagedWindow) -> Void
    /// Whether another mode currently owns the pointer or keyboard, such as aiming or search.
    var isSuspended: () -> Bool = { false }

    private var monitor: Any?
    private var pending: DispatchWorkItem?

    /// Window level of pull-down and context menus.
    private static let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

    init(model: WindowQueueModel, store: PreferencesStore, focus: @escaping (ManagedWindow) -> Void) {
        self.model = model
        self.store = store
        self.focus = focus
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.pointerMoved()
        }
    }

    private func pointerMoved() {
        pending?.cancel()
        guard store.prefs.focusFollowsMouse else { return }
        let item = DispatchWorkItem { [weak self] in self?.focusWindowUnderPointer() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + store.prefs.focusFollowsMouseDelay, execute: item)
    }

    private func focusWindowUnderPointer() {
        pending = nil
        guard store.prefs.focusFollowsMouse,
              !isSuspended(),
              NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        else { return }

        guard let id = Self.windowUnderPointer(),
              let window = model.windows.first(where: { $0.id == id }),
              window.pid != ProcessInfo.processInfo.processIdentifier,
              !window.isMinimized
        else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard !(window.id == model.selectedID && window.pid == frontmost) else { return }

        Diagnostics.note("hover focus \(window.appName) id=\(window.id)")
        model.select(id: window.id, announce: false)
        focus(window)
    }

    /// The ordinary window directly under the pointer, or nil when anything else is on top there
    /// or a menu is open anywhere.
    static func windowUnderPointer() -> CGWindowID? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoa = NSEvent.mouseLocation
        let point = CGPoint(x: cocoa.x, y: primary.frame.height - cocoa.y)

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        if list.contains(where: { ($0[kCGWindowLayer as String] as? Int) == menuLayer }) {
            return nil
        }

        // Front to back: the first window containing the point is the one the pointer is over.
        for info in list {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha <= 0 { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}
