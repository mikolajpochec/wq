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

        let known = Set(model.windows.map(\.id))
        guard let id = Self.windowUnderPointer(isKnown: known.contains),
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
    ///
    /// The WindowServer is asked which window a click there would reach, so windows that let the
    /// mouse through — the invisible full-screen overlay the Screenshot utility leaves behind, a
    /// fading outline — do not count as being in the way. A hit on a helper window of an app — the
    /// tab hover card Chrome floats over its tab strip — is passed on to the first known window of
    /// the same app beneath it.
    static func windowUnderPointer(isKnown: (CGWindowID) -> Bool = { _ in true }) -> CGWindowID? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoa = NSEvent.mouseLocation
        let point = CGPoint(x: cocoa.x, y: primary.frame.height - cocoa.y)

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        if list.contains(where: { ($0[kCGWindowLayer as String] as? Int) == menuLayer }) {
            return nil
        }

        func number(_ info: [String: Any]) -> CGWindowID? {
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        func contains(_ info: [String: Any]) -> Bool {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return false }
            return bounds.contains(point)
        }
        func isOrdinary(_ info: [String: Any]) -> Bool {
            (info[kCGWindowLayer as String] as? Int) == 0
        }

        if let hit = serverWindow(at: point) {
            // Not in the list: the desktop, or something else that is not a window to focus.
            guard let index = list.firstIndex(where: { number($0) == hit }),
                  isOrdinary(list[index])
            else { return nil }
            if isKnown(hit) { return hit }
            let owner = list[index][kCGWindowOwnerPID as String] as? pid_t
            return list[index...].first { info in
                isOrdinary(info) && contains(info)
                    && info[kCGWindowOwnerPID as String] as? pid_t == owner
                    && number(info).map(isKnown) == true
            }.flatMap(number)
        }

        // Front to back: the first window containing the point is the one the pointer is over.
        for info in list {
            guard contains(info) else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha <= 0 { continue }
            guard isOrdinary(info) else { return nil }
            return number(info)
        }
        return nil
    }

    private typealias FindWindowFn = @convention(c) (Int32, Int32, Int32, Int32, UnsafeMutablePointer<CGPoint>,
                                                     UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<UInt32>,
                                                     UnsafeMutablePointer<Int32>) -> Int32
    private typealias ConnectionFn = @convention(c) () -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let findWindowAndOwner = skyLight.flatMap { dlsym($0, "SLSFindWindowAndOwner") }
        .map { unsafeBitCast($0, to: FindWindowFn.self) }
    private static let connection = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }
        .map { unsafeBitCast($0, to: ConnectionFn.self)() }

    /// The window the WindowServer would deliver a click at this point to — the hit test yabai
    /// uses. Nil when the private symbols are missing, and the window list is walked instead.
    private static func serverWindow(at point: CGPoint) -> CGWindowID? {
        guard let findWindowAndOwner, let connection else { return nil }
        var point = point
        var local = CGPoint.zero
        var windowID: UInt32 = 0
        var owner: Int32 = 0
        guard findWindowAndOwner(connection, 0, 1, 0, &point, &local, &windowID, &owner) == 0,
              windowID != 0
        else { return nil }
        return windowID
    }
}
