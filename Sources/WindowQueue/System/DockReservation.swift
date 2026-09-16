import AppKit

/// Reserves room for the strip the way the Dock does, by handing the WindowServer a Dock rectangle.
///
/// Every app works out `NSScreen.visibleFrame` from a single "Dock rect" plus the edge the Dock is
/// on, which the WindowServer keeps and which any process can overwrite. Zoom, Fill and the
/// built-in tiling all size windows to that frame, so a rect the width of the strip makes them
/// leave room for it natively.
///
/// Two limits come with it. Apps read the rect when they start and keep it until the Dock announces
/// a change, which carries the Dock's own values and cannot be sent by anyone else: apps already
/// running when the rect is set do not see it, and every app forgets it whenever the Dock rewrites
/// its rect (a Dock restart, a display change, a Dock setting). And there is one rect, so it covers
/// one screen — the one with the menu bar. `ScreenEdgeGuard` stays in place for everything else.
///
/// The Dock's own rect is only replaced while the Dock hides itself; a visible Dock needs its
/// reservation more than the strip does. It is saved to disk before being replaced, so a crash
/// cannot leave the WindowServer with a strip-shaped Dock once WindowQueue is gone.
final class DockReservation {
    static var shared: DockReservation?

    private struct DockRect: Codable, Equatable {
        var x, y, width, height: Double
        var reason: Int32
        var orientation: Int32

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias GetFn = @convention(c) (Int32, UnsafeMutablePointer<CGRect>,
                                               UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias SetFn = @convention(c) (Int32, Double, Double, Double, Double, Int32, Int32) -> Int32
    private typealias AutoHideFn = @convention(c) () -> Bool

    /// `kCoreDockOrientation…` for each edge.
    private static func orientation(for side: StripSide) -> Int32 {
        switch side {
        case .top: return 1
        case .bottom: return 2
        case .left: return 3
        case .right: return 4
        }
    }
    /// Reason the Dock reports while it is showing, as opposed to hidden.
    private static let shownReason: Int32 = 0
    private static let savedKey = "dockReservation.originalRect.v1"

    private let store: PreferencesStore
    private let connectionID: Int32
    private let get: GetFn?
    private let set: SetFn?
    private let autoHideEnabled: AutoHideFn?

    /// The rect we last installed, to tell our own value apart from one the Dock has written since.
    private var installed: DockRect?
    private var timer: Timer?
    /// Until when the Dock's own rect is deliberately left in place, while an app that has to see
    /// the unreserved screen starts up.
    private var suspendedUntil: Date?

    init(store: PreferencesStore) {
        self.store = store
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connectionID = symbol(skyLight, "CGSMainConnectionID", as: ConnectionFn.self)?() ?? 0
        get = symbol(skyLight, "SLSGetDockRectWithOrientation", as: GetFn.self)
        set = symbol(skyLight, "SLSSetDockRectWithOrientation", as: SetFn.self)
        autoHideEnabled = symbol(services, "CoreDockGetAutoHideEnabled", as: AutoHideFn.self)
    }

    var isAvailable: Bool { connectionID != 0 && get != nil && set != nil }

    func start() {
        guard isAvailable else { return }
        // A rect left behind by a previous run that did not get to clean up.
        if let saved = savedOriginal, current().map(looksLikeOurs) == true {
            write(saved)
        }
        // Each process reads the rect once and keeps it. Make WindowQueue's own read happen now,
        // before the reservation goes in: the strip and the edge guard measure the screen as the
        // Dock leaves it, and would otherwise count the strip's room twice.
        _ = NSScreen.screens.first?.visibleFrame
        update()
        // The Dock rewrites its rect whenever its geometry changes; notice and take the edge back.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.update() }
    }

    /// Re-evaluates after a settings change, installing, moving or removing the reservation.
    func update() {
        if let suspendedUntil, suspendedUntil > Date() { return }
        suspendedUntil = nil
        guard isAvailable, let current = current() else { return }

        if current != installed {
            // Whatever is there and is not ours is the Dock's latest word, so it is what to restore.
            if installed != nil || !looksLikeOurs(current) {
                savedOriginal = current
            }
            installed = nil
        }

        guard let wanted = wantedRect() else {
            restore()
            return
        }
        guard wanted != current else {
            installed = wanted
            return
        }
        if savedOriginal == nil { savedOriginal = current }
        write(wanted)
        installed = wanted
        Diagnostics.note("dock reservation: \(wanted.rect) orientation \(wanted.orientation)")
    }

    /// Hands the rect back to the Dock. Call on quit.
    func restore() {
        guard isAvailable, let original = savedOriginal else { return }
        if let current = current(), current == installed || looksLikeOurs(current) {
            write(original)
        }
        installed = nil
        savedOriginal = nil
    }

    /// Whether the rect is currently reserving space.
    var isInstalled: Bool { installed != nil }

    /// Puts the Dock's rect back for a while, so an app launched meanwhile reads the real screen.
    ///
    /// Rectangle needs this: it adds its own screen-edge gap on top of the visible frame it read at
    /// launch, and a frame that already leaves room for the strip would make the gap twice as wide.
    func suspend(for duration: TimeInterval) {
        guard isAvailable else { return }
        suspendedUntil = Date().addingTimeInterval(duration)
        if let original = savedOriginal, let current = current(), current == installed {
            write(original)
        }
        installed = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in self?.update() }
    }

    // MARK: - Rects

    private func wantedRect() -> DockRect? {
        let prefs = store.prefs
        guard prefs.reserveScreenSpace, prefs.stripDisplay != .hidden,
              autoHideEnabled?() ?? false,
              let screen = NSScreen.screens.first
        else { return nil }

        let gap = Double(RectangleIntegration.reservedWidth(for: prefs))
        // Global coordinates with the origin at the top left of the menu bar screen.
        let menuBarHeight = Double(screen.frame.maxY - screen.visibleFrame.maxY)
        let width = Double(screen.frame.width)
        let height = Double(screen.frame.height)
        let rect: (x: Double, y: Double, width: Double, height: Double)
        switch prefs.stripSide {
        case .left: rect = (0, menuBarHeight, gap, height - menuBarHeight)
        case .right: rect = (width - gap, menuBarHeight, gap, height - menuBarHeight)
        case .top: rect = (0, menuBarHeight, width, gap)
        case .bottom: rect = (0, height - gap, width, gap)
        }
        return DockRect(x: Double(screen.frame.minX) + rect.x, y: rect.y, width: rect.width, height: rect.height,
                        reason: Self.shownReason,
                        orientation: Self.orientation(for: prefs.stripSide))
    }

    /// A left or right rect with the shown reason — which the Dock itself never writes while hidden.
    private func looksLikeOurs(_ rect: DockRect) -> Bool {
        // A shown Dock never reports itself while auto-hide is on, so a "shown" rect then is ours.
        rect.reason == Self.shownReason && (autoHideEnabled?() ?? false)
    }

    private func current() -> DockRect? {
        guard let get else { return nil }
        var rect = CGRect.zero
        var reason: Int32 = 0
        var orientation: Int32 = 0
        guard get(connectionID, &rect, &reason, &orientation) == 0 else { return nil }
        return DockRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                        reason: reason, orientation: orientation)
    }

    private func write(_ rect: DockRect) {
        _ = set?(connectionID, rect.x, rect.y, rect.width, rect.height, rect.reason, rect.orientation)
    }

    private var savedOriginal: DockRect? {
        get {
            UserDefaults.standard.data(forKey: Self.savedKey)
                .flatMap { try? JSONDecoder().decode(DockRect.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.savedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.savedKey)
            }
        }
    }
}
