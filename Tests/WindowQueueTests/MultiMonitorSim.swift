import XCTest
@testable import WindowQueue

/// A pretend multi-display desktop for the monitor shortcuts, end to end: screens in any
/// arrangement (left of, above, below the primary, mixed sizes), each with its own desktops, a
/// window server with a front-to-back order, apps that keep a minimum size, a pointer, and the real
/// `WindowQueueModel` fed the way `WindowEnumerator` feeds it (WindowServer coordinates, monitors
/// left to right, the display holding the key window as the current one).
///
/// The actions follow `AppDelegate` step for step (`moveWindows(toMonitor:)`, `focusMonitor`,
/// `maximize`, `toggleMaximize`, `noteLaunch`/`placeLaunched`), with every decision taken by
/// `MonitorPlanner` exactly as the app takes it; only the AX and window-server calls are simulated.
final class MultiMonitorSim {
    struct Screen {
        let id: CGDirectDisplayID
        /// Cocoa coordinates; the first screen is the primary one, origin (0, 0).
        var frame: NSRect
        var menuBar: CGFloat = 24
        /// The Dock, along the bottom (primary display only, by default).
        var dock: CGFloat = 0
        var spaces: [UInt64]
        var shown: UInt64
        var name: String
    }

    struct Window {
        let id: CGWindowID
        var app: String
        var pid: pid_t
        /// Cocoa coordinates.
        var frame: NSRect
        var space: UInt64?
        var minimized = false
        var minSize = NSSize(width: 1, height: 1)
        /// False for a window whose app does not answer AX (no element, no frame).
        var measurable = true
    }

    var screens: [Screen]
    var windows: [CGWindowID: Window] = [:]
    /// Front to back, like `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`.
    var zOrder: [CGWindowID] = []
    var prefs: Preferences
    let model = WindowQueueModel()
    /// Cocoa coordinates.
    var pointer: CGPoint
    var keyWindow: CGWindowID?

    // AppDelegate state mirrored.
    var framesBeforeMaximize: [CGWindowID: NSRect] = [:]
    var pointerOnlyMonitor: (display: CGDirectDisplayID, selectedID: CGWindowID?)?
    var launchTarget: (display: CGDirectDisplayID, at: Date)?
    var clock = Date(timeIntervalSince1970: 1_000_000)

    // What the user saw.
    var toasts: [String] = []
    var flashes: [CGDirectDisplayID] = []
    var warps: [CGPoint] = []

    init(_ screens: [Screen], prefs: Preferences = MultiMonitorSim.defaultPrefs) {
        precondition(!screens.isEmpty && screens[0].frame.origin == .zero, "the first screen is the primary one")
        self.screens = screens
        self.prefs = prefs
        pointer = CGPoint(x: screens[0].frame.midX, y: screens[0].frame.midY)
        model.scope = .monitor
        model.queuePerMonitor = prefs.multiMonitorMode
        refresh()
    }

    static var defaultPrefs: Preferences {
        var prefs = Preferences()
        prefs.stripSide = .left
        prefs.multiMonitorMode = true
        prefs.tileOuterGap = 0
        prefs.tileInnerGap = 4
        return prefs
    }

    var gaps: WindowTiler.Gaps { WindowTiler.Gaps(prefs: prefs) }
    var primaryHeight: CGFloat { screens[0].frame.height }

    // MARK: - Layouts

    /// The user's desk: a Dell on the left, the main display, the laptop's own screen on the right.
    static func usersDesk(prefs: Preferences = defaultPrefs) -> MultiMonitorSim {
        MultiMonitorSim([
            Screen(id: 2, frame: NSRect(x: 0, y: 0, width: 3008, height: 1692), dock: 60,
                   spaces: [20, 21], shown: 20, name: "Main"),
            Screen(id: 1, frame: NSRect(x: -2560, y: 0, width: 2560, height: 1440),
                   spaces: [10, 11], shown: 10, name: "Dell"),
            Screen(id: 3, frame: NSRect(x: 3008, y: 0, width: 1512, height: 982),
                   spaces: [30], shown: 30, name: "Built-in"),
        ], prefs: prefs)
    }

    // MARK: - Windows

    @discardableResult
    func open(_ id: CGWindowID, _ app: String, _ frame: NSRect, minSize: NSSize = NSSize(width: 1, height: 1),
              pid: pid_t? = nil, focus: Bool = true) -> Window {
        let holder = screenIndex(holding: frame)
        let window = Window(id: id, app: app, pid: pid ?? pid_t(id), frame: frame,
                            space: holder.map { screens[$0].shown }, minSize: minSize)
        windows[id] = window
        zOrder.insert(id, at: 0)
        refresh()
        if focus { self.focus(id) }
        return window
    }

    /// A window in the middle of a screen, a fraction of its room.
    @discardableResult
    func open(_ id: CGWindowID, _ app: String, on display: CGDirectDisplayID, fraction: CGFloat = 0.5,
              minSize: NSSize = NSSize(width: 1, height: 1), focus: Bool = true) -> Window {
        let area = self.area(of: display)
        let frame = NSRect(x: area.midX - area.width * fraction / 2, y: area.midY - area.height * fraction / 2,
                           width: area.width * fraction, height: area.height * fraction).integral
        return open(id, app, frame, minSize: minSize, focus: focus)
    }

    func close(_ id: CGWindowID) {
        windows[id] = nil
        zOrder.removeAll { $0 == id }
        if keyWindow == id { keyWindow = zOrder.first }
        refresh()
    }

    /// Focusing a window: it comes to the front, takes the keyboard, and its screen becomes the main one.
    func focus(_ id: CGWindowID) {
        guard windows[id] != nil else { return }
        keyWindow = id
        zOrder.removeAll { $0 == id }
        zOrder.insert(id, at: 0)
        refresh()
        model.select(id: id, announce: false)
    }

    /// The app's own answer when asked for a frame, as `WindowTiler.setFrame` gets it.
    func setFrame(_ id: CGWindowID, _ frame: NSRect) {
        guard var window = windows[id] else { return }
        window.frame = NSRect(x: frame.minX, y: frame.maxY - max(frame.height, window.minSize.height),
                              width: max(frame.width, window.minSize.width),
                              height: max(frame.height, window.minSize.height))
        windows[id] = window
    }

    /// `WindowTiler.fill`.
    func fill(_ id: CGWindowID, in area: NSRect) {
        setFrame(id, MonitorPlanner.filledFrame(in: area, gaps: gaps))
    }

    /// The frame `WindowTiler.frame(of:)` / `serverFrame(of:)` reads.
    func measuredFrame(_ id: CGWindowID) -> NSRect? {
        guard let window = windows[id], window.measurable else { return nil }
        return window.frame
    }

    // MARK: - Screens

    var displays: [MonitorPlanner.Display] {
        MonitorPlanner.ordered(screens.map { screen in
            MonitorPlanner.Display(id: screen.id, frame: screen.frame,
                                   area: MonitorPlanner.stripReduced(visibleFrame(screen), prefs: prefs))
        })
    }

    func visibleFrame(_ screen: Screen) -> NSRect {
        var frame = screen.frame
        frame.size.height -= screen.menuBar
        frame.origin.y += screen.dock
        frame.size.height -= screen.dock
        return frame
    }

    /// `AppDelegate.tilingArea(on:)`.
    func area(of display: CGDirectDisplayID) -> NSRect {
        displays.first { $0.id == display }!.area
    }

    func screenIndex(holding frame: NSRect) -> Int? {
        let overlaps = screens.map { MonitorPlanner.overlap($0.frame, frame) }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { return nil }
        return best
    }

    /// The display a window is on, by its frame (what the window server knows).
    func display(of id: CGWindowID) -> CGDirectDisplayID? {
        windows[id].flatMap { screenIndex(holding: $0.frame) }.map { screens[$0].id }
    }

    /// Monitor number (1-based, left to right) of a display.
    func number(of display: CGDirectDisplayID?) -> Int? {
        displays.firstIndex { $0.id == display }.map { $0 + 1 }
    }

    /// `NSScreen.main`: the screen with the key window, else the one with the pointer.
    var mainDisplay: CGDirectDisplayID {
        if let key = keyWindow, let display = display(of: key) { return display }
        return screens.first { $0.frame.contains(pointer) }?.id ?? screens[0].id
    }

    func plug(_ screen: Screen) {
        screens.append(screen)
        refresh()
    }

    /// Unplugging a display: macOS gathers its windows on the primary one, top left, kept inside it,
    /// and they join the desktop on show there.
    func unplug(_ display: CGDirectDisplayID) {
        guard let index = screens.firstIndex(where: { $0.id == display }), index != 0 else { return }
        let gone = screens.remove(at: index)
        let primary = screens[0]
        let room = visibleFrame(primary)
        for (id, var window) in windows where window.space.map(gone.spaces.contains) ?? false
            || (screenIndex(holding: window.frame) == nil) {
            let size = NSSize(width: min(window.frame.width, room.width), height: min(window.frame.height, room.height))
            let offset = window.frame.origin.applying(.init(translationX: -gone.frame.minX, y: -gone.frame.minY))
            window.frame = NSRect(x: min(room.minX + offset.x, room.maxX - size.width),
                                  y: min(max(room.minY + offset.y, room.minY), room.maxY - size.height),
                                  width: size.width, height: size.height)
            window.space = primary.shown
            windows[id] = window
        }
        if screens.allSatisfy({ !$0.frame.contains(pointer) }) {
            pointer = CGPoint(x: primary.frame.midX, y: primary.frame.midY)
        }
        refresh()
    }

    // MARK: - Enumeration

    /// What `WindowEnumerator.refresh` + `refreshSpaceState` hand the model. A window moved to
    /// another display joins the desktop that display has on show, as macOS does.
    func refresh() {
        for (id, var window) in windows {
            guard let holder = screenIndex(holding: window.frame) else { continue }
            if window.space.map({ !screens[holder].spaces.contains($0) }) ?? true {
                window.space = screens[holder].shown
                windows[id] = window
            }
        }
        let ordered = screens.sorted { MonitorPlanner.isOrderedBefore($0.frame, $1.frame) }
        let monitors = ordered.map { screen in
            WindowQueueModel.Monitor(id: screen.id,
                                     frame: MonitorPlanner.flipped(screen.frame, primaryHeight: primaryHeight),
                                     spaceIDs: Set(screen.spaces), shownSpaceID: screen.shown)
        }
        if model.monitors != monitors { model.monitors = monitors }
        let order = ordered.flatMap(\.spaces)
        if model.spaceOrder != order { model.spaceOrder = order }
        let main = mainDisplay
        if model.currentMonitorID != main { model.currentMonitorID = main }
        let shown = screens.first { $0.id == main }?.shown
        if model.currentSpaceID != shown { model.currentSpaceID = shown }
        model.reconcile(with: windows.values.sorted { $0.id < $1.id }.map { window in
            ManagedWindow(id: window.id, element: nil, pid: window.pid, appName: window.app, bundleID: nil,
                          title: window.app, isMinimized: window.minimized, spaceID: window.space,
                          frame: MonitorPlanner.flipped(window.frame, primaryHeight: primaryHeight))
        })
    }

    // MARK: - Actions (AppDelegate, step for step)

    /// `AppDelegate.workedOnDisplay`.
    func workedOnDisplay() -> CGDirectDisplayID? {
        if let pointed = pointerOnlyMonitor, pointed.selectedID == model.selectedID { return pointed.display }
        return model.selectedWindow.flatMap(model.monitorID(of:)) ?? mainDisplay
    }

    /// `AppDelegate.moveWindows(toMonitor:)`: the selected window, or the given (aimed) ones.
    func moveToMonitor(_ number: Int?, aimed: [CGWindowID]? = nil) {
        let ids = aimed ?? model.selectedID.map { [$0] } ?? []
        guard prefs.multiMonitorMode, !ids.isEmpty else { return }
        let displays = self.displays
        let plan = MonitorPlanner.planMove(ids.map { ($0, measuredFrame($0)) }, toMonitor: number,
                                           displays: displays, gaps: gaps)
        switch plan {
        case .onlyOne:
            toasts.append("Only one monitor")
        case .missing(let number, _):
            toasts.append("No monitor \(number)")
        case .nothing:
            break
        case .alreadyThere(let target):
            toasts.append("Already on monitor \(target + 1)")
        case .move(let target, let lead, let moves):
            for move in moves {
                relocate(move.id, move.landing, from: displays[move.from].area, to: displays[target].area)
            }
            if displays[target].id != displays[lead].id { markMonitor(displays[target].id) }
            let first = moves[0].id
            model.select(id: first, announce: false)
            focus(first)
            toasts.append("Moved to monitor \(target + 1)")
        }
        refresh()
    }

    /// `AppDelegate.relocate`.
    func relocate(_ id: CGWindowID, _ landing: MonitorPlanner.Landing, from source: NSRect, to target: NSRect) {
        if let carried = MonitorPlanner.carried(framesBeforeMaximize[id], from: source, to: target) {
            framesBeforeMaximize[id] = carried
        }
        if landing.fills { fill(id, in: target) } else { setFrame(id, landing.frame) }
    }

    /// `AppDelegate.focusMonitor`.
    func focusMonitor(_ number: Int?) {
        guard prefs.multiMonitorMode else { return }
        let displays = self.displays
        let selectedID = model.selectedID
        let currentDisplay = workedOnDisplay()
        let current = displays.firstIndex { $0.id == currentDisplay }
        switch MonitorPlanner.target(number: number, after: current ?? 0, count: displays.count) {
        case .onlyOne:
            toasts.append("Only one monitor")
        case .missing(let number, _):
            toasts.append("No monitor \(number)")
        case .index(let index):
            pointerOnlyMonitor = nil
            let display = displays[index].id
            if display != currentDisplay { markMonitor(display) }
            let onShow = Set(onScreenFrontToBack)
            let candidates = model.windows.filter {
                !$0.isMinimized && onShow.contains($0.id) && model.monitorID(of: $0) == display
            }.map(\.id)
            if let landed = MonitorPlanner.landing(among: candidates, frontToBack: onScreenFrontToBack) {
                model.select(id: landed, announce: true)
                focus(landed)
                return
            }
            let point = MonitorPlanner.warpPoint(for: displays[index].frame, primaryHeight: primaryHeight)
            warps.append(point)
            // Only the pointer moves: the key window, and so `NSScreen.main`, stay where they were.
            pointer = CGPoint(x: point.x, y: primaryHeight - point.y)
            pointerOnlyMonitor = (display, selectedID)
            refresh()
        }
    }

    var onScreenFrontToBack: [CGWindowID] {
        zOrder.filter { id in
            guard let window = windows[id], !window.minimized, let holder = screenIndex(holding: window.frame)
            else { return false }
            return window.space == screens[holder].shown
        }
    }

    /// `AppDelegate.tilingArea(of:)`: the room on the screen the window is on.
    func tilingArea(of id: CGWindowID) -> NSRect {
        if let frame = measuredFrame(id), let index = MonitorPlanner.index(holding: frame, in: displays) {
            return displays[index].area
        }
        return area(of: mainDisplay)
    }

    /// `AppDelegate.maximize` (⌥M).
    func maximize() {
        guard let id = model.selectedID else { return }
        if framesBeforeMaximize[id] == nil { framesBeforeMaximize[id] = measuredFrame(id) }
        fill(id, in: tilingArea(of: id))
        focus(id)
    }

    /// `AppDelegate.toggleMaximize` (fullscreen toggle).
    func toggleFullscreen() {
        guard let id = model.selectedID else { return }
        let area = tilingArea(of: id)
        if let stored = framesBeforeMaximize[id], let frame = measuredFrame(id),
           MonitorPlanner.fills(frame, area, gaps: gaps) {
            framesBeforeMaximize[id] = nil
            setFrame(id, MonitorPlanner.restoreFrame(stored, current: frame, area: area, displays: displays))
            refresh()
            return
        }
        framesBeforeMaximize[id] = measuredFrame(id)
        fill(id, in: area)
        focus(id)
    }

    /// `AppDelegate.noteLaunch`: a launcher opened from the monitor worked on.
    func noteLaunch() {
        launchTarget = screens.count > 1 ? workedOnDisplay().map { ($0, clock) } : nil
    }

    /// An app opening a window where macOS puts it (`frame`), then `AppDelegate.placeLaunched`.
    func launch(_ id: CGWindowID, _ app: String, at frame: NSRect, minSize: NSSize = NSSize(width: 1, height: 1)) {
        open(id, app, frame, minSize: minSize)
        guard let target = launchTarget else { return }
        guard clock.timeIntervalSince(target.at) < 20 else {
            launchTarget = nil
            return
        }
        launchTarget = nil
        let displays = self.displays
        guard let frame = measuredFrame(id),
              let source = MonitorPlanner.index(holding: frame, in: displays),
              let destination = displays.firstIndex(where: { $0.id == target.display }),
              source != destination
        else { return }
        relocate(id, MonitorPlanner.relocate(frame, from: displays[source].area, to: displays[destination].area,
                                             gaps: gaps),
                 from: displays[source].area, to: displays[destination].area)
        refresh()
    }

    func markMonitor(_ display: CGDirectDisplayID) {
        guard prefs.flashMonitorOnSwitch, screens.count > 1 else { return }
        flashes.append(display)
    }

    // MARK: - What the strips show

    /// Window ids on the strip of monitor `number` (1-based, left to right).
    func strip(_ number: Int) -> [CGWindowID] {
        model.stripWindows(onMonitor: displays[number - 1].id).map(\.id)
    }

    /// The monitor number the strip showing a window is on.
    func stripNumber(of id: CGWindowID) -> Int? {
        (1...displays.count).first { strip($0).contains(id) }
    }

    /// Everything that must hold whatever was done: each window on exactly one monitor's strip and
    /// that one is the monitor it is on; the model's monitors are the screens left to right; nothing
    /// lost off every screen.
    func checkInvariants(_ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let displays = self.displays
        XCTAssertEqual(model.monitors.map(\.id), displays.map(\.id), "monitors left to right \(context)",
                       file: file, line: line)
        for window in windows.values {
            XCTAssertNotNil(screenIndex(holding: window.frame), "window \(window.id) off every screen \(context)",
                            file: file, line: line)
        }
        guard model.queuePerMonitor, model.scope == .monitor else { return }
        var seen: [CGWindowID: Int] = [:]
        for number in 1...displays.count {
            for id in strip(number) {
                if let other = seen[id] {
                    XCTFail("window \(id) on strips \(other) and \(number) \(context)", file: file, line: line)
                }
                seen[id] = number
                if let shown = windows[id], displays.count > 1 {
                    XCTAssertEqual(display(of: shown.id), displays[number - 1].id,
                                   "window \(id) on strip \(number) but on screen \(self.number(of: display(of: id)) ?? 0) \(context)",
                                   file: file, line: line)
                }
            }
        }
        XCTAssertEqual(Set(seen.keys), Set(windows.keys), "every window on some strip \(context)", file: file, line: line)
        XCTAssertEqual(Set(model.visibleWindows.map(\.id)), Set(strip(number(of: model.currentMonitorID) ?? 1)),
                       "the keyboard works on the focused monitor's queue \(context)", file: file, line: line)
    }
}
