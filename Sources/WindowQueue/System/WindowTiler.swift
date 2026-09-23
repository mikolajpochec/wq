import AppKit
import ApplicationServices

/// An arrangement for a group of windows: one unit rect per window, origin at the top left.
struct TileLayout: Identifiable, Equatable {
    let name: String
    let frames: [CGRect]

    var id: String { name }

    /// The same arrangement whatever the count: "Side by side" for two is "Columns" for three.
    var kind: String {
        switch name {
        case "Side by side": return "Columns"
        case "Stacked": return "Rows"
        default: return name
        }
    }

    /// The arrangements that make sense for this many windows, most useful first.
    static func options(for count: Int) -> [TileLayout] {
        guard count >= 2 else { return [] }
        var layouts: [TileLayout] = []
        if count >= 4 { layouts.append(grid(count)) }
        if count >= 3 { layouts.append(mainAndStack(count)) }
        layouts.append(TileLayout(name: count == 2 ? "Side by side" : "Columns", frames: columns(count)))
        layouts.append(TileLayout(name: count == 2 ? "Stacked" : "Rows", frames: rows(count)))
        return layouts
    }

    private static func columns(_ count: Int) -> [CGRect] {
        let width = 1 / CGFloat(count)
        return (0..<count).map { CGRect(x: CGFloat($0) * width, y: 0, width: width, height: 1) }
    }

    private static func rows(_ count: Int) -> [CGRect] {
        let height = 1 / CGFloat(count)
        return (0..<count).map { CGRect(x: 0, y: CGFloat($0) * height, width: 1, height: height) }
    }

    /// The first window takes the left half; the rest share the right half, stacked.
    private static func mainAndStack(_ count: Int) -> TileLayout {
        let others = count - 1
        let height = 1 / CGFloat(others)
        let stack = (0..<others).map { CGRect(x: 0.5, y: CGFloat($0) * height, width: 0.5, height: height) }
        return TileLayout(name: "Main and stack", frames: [CGRect(x: 0, y: 0, width: 0.5, height: 1)] + stack)
    }

    /// Rows filled left to right; a short last row spreads its windows across the full width.
    private static func grid(_ count: Int) -> TileLayout {
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = 1 / CGFloat(rows)
        var frames: [CGRect] = []
        for row in 0..<rows {
            let inRow = min(columns, count - row * columns)
            let width = 1 / CGFloat(inRow)
            for column in 0..<inRow {
                frames.append(CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height))
            }
        }
        return TileLayout(name: "Grid", frames: frames)
    }
}

/// Lays windows out in a `TileLayout` through the Accessibility API.
enum WindowTiler {
    /// How much room to leave around tiled windows.
    struct Gaps {
        var outer: CGFloat = 0
        var inner: CGFloat = 0

        init(outer: CGFloat, inner: CGFloat) {
            self.outer = outer
            self.inner = inner
        }

        init(prefs: Preferences) {
            outer = CGFloat(prefs.tileOuterGap)
            inner = CGFloat(prefs.tileInnerGap)
        }
    }

    /// - Parameter area: the space to fill, in Cocoa screen coordinates.
    /// - Returns: the windows that were placed; a window with no accessibility element — one on a
    ///   workspace not visited yet — cannot be.
    @discardableResult
    static func tile(_ windows: [ManagedWindow], layout: TileLayout, in area: NSRect,
                     gaps: Gaps = Gaps(outer: 0, inner: 0)) -> [ManagedWindow] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Each cell gives up half the inner gap on every side, so two neighbours leave a whole one
        // between them; taking that half back out of the area keeps the outer gap exactly as asked.
        let inset = gaps.outer - gaps.inner / 2
        let area = area.insetBy(dx: inset, dy: inset)
        // Accessibility coordinates start at the top left of the menu bar screen, y downwards.
        let top = primaryHeight - area.maxY
        var placed: [ManagedWindow] = []

        for (window, unit) in zip(windows, layout.frames) {
            guard let element = window.element else { continue }
            let cell = CGRect(x: (area.minX + unit.minX * area.width).rounded(),
                              y: (top + unit.minY * area.height).rounded(),
                              width: (unit.width * area.width).rounded(),
                              height: (unit.height * area.height).rounded())
            let frame = cell.insetBy(dx: gaps.inner / 2, dy: gaps.inner / 2)
            if window.isMinimized {
                element.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
            }
            setFrame(frame, of: element, window: window)
            placed.append(window)
        }
        Diagnostics.note("tiled \(placed.count)/\(windows.count) windows as \(layout.name)")
        return placed
    }

    /// The frame request each window is currently following. A window told to go somewhere else —
    /// maximized and then restored, say — must not have the older request put back underneath it.
    private static var currentRequest: [CGWindowID: Int] = [:]
    /// The frame each window was last given, so nothing else corrects a window we just placed.
    private(set) static var placedFrames: [CGWindowID: CGRect] = [:]
    private static var lastRequest = 0

    /// When to look at a tiled window again. A window that has just arrived from another
    /// workspace, or whose app animates or snaps its own frame, can accept a size and then lose the
    /// position, so the whole frame is checked a few times and set again whenever it slipped.
    private static let checkDelays: [TimeInterval] = [0.15, 0.4, 0.8, 1.5]

    private static func setFrame(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow) {
        lastRequest += 1
        currentRequest[window.id] = lastRequest
        placedFrames[window.id] = frame
        apply(frame, of: element, window: window, request: lastRequest, check: 0)
    }

    private static func apply(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow,
                              request: Int, check: Int) {
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return }
        withoutAnimation(pid: window.pid) {
            // Move first, then resize: one pass, and the window is never drawn at the new size in
            // the old place, which reads as a flicker.
            element.setAttribute(kAXPositionAttribute, value: originValue)
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
            // Apps that clamp a resize against where the window was need the other order, but only
            // those: asking for it every time is what caused the flicker.
            guard let landed = currentFrame(of: element), !matches(landed, frame) else { return }
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
            element.setAttribute(kAXPositionAttribute, value: originValue)
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
        }

        scheduleCheck(frame, of: element, window: window, request: request, check: check, seen: nil)
    }

    /// Runs the frame change with the app's `AXEnhancedUserInterface` switched off.
    ///
    /// AppKit animates every frame an accessibility client sets while that attribute is on, which
    /// makes a window crawl into place instead of arriving there. WindowQueue turns the attribute on
    /// itself, for apps that otherwise hide their windows, so it has to take it back off around a
    /// move — the same thing Rectangle does — and put it back afterwards.
    private static func withoutAnimation(pid: pid_t, _ body: () -> Void) {
        let app = AXPrivate.application(pid)
        let wasEnhanced = app.boolAttribute("AXEnhancedUserInterface") ?? false
        if wasEnhanced { app.setAttribute("AXEnhancedUserInterface", value: kCFBooleanFalse) }
        body()
        if wasEnhanced { app.setAttribute("AXEnhancedUserInterface", value: kCFBooleanTrue) }
    }

    /// Whether this is where WindowQueue itself last put the window, in accessibility coordinates.
    static func placed(_ id: CGWindowID, at frame: CGRect) -> Bool {
        guard let target = placedFrames[id] else { return false }
        return matches(frame, target)
    }

    /// Close enough to count as the frame we asked for; apps round sizes to their own grids.
    static func matches(_ frame: CGRect, _ target: CGRect) -> Bool {
        abs(frame.minX - target.minX) <= 2 && abs(frame.minY - target.minY) <= 2
            && abs(frame.width - target.width) <= 2 && abs(frame.height - target.height) <= 2
    }

    /// - Parameter seen: where the window was at the previous check, so a frame still on its way
    ///   is left to arrive instead of being fought mid-flight.
    private static func scheduleCheck(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow,
                                      request: Int, check: Int, seen: CGRect?) {
        guard checkDelays.indices.contains(check) else { return }
        let wait = checkDelays[check] - (check == 0 ? 0 : checkDelays[check - 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            // A newer frame request has taken this window over.
            guard currentRequest[window.id] == request, let current = currentFrame(of: element) else { return }
            if matches(current, frame) {
                scheduleCheck(frame, of: element, window: window, request: request, check: check + 1, seen: current)
                return
            }
            guard let seen, matches(current, seen) else {
                // Still moving: look again before deciding it went wrong.
                scheduleCheck(frame, of: element, window: window, request: request, check: check + 1, seen: current)
                return
            }
            Diagnostics.note("tiling: \(window.appName) id=\(window.id) settled at \(current), setting \(frame) again")
            apply(frame, of: element, window: window, request: request, check: check + 1)
        }
    }

    private static func currentFrame(of element: AXUIElement) -> CGRect? {
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

    /// Fills the area with one window, as a maximize does.
    @discardableResult
    static func fill(_ window: ManagedWindow, in area: NSRect, gaps: Gaps = Gaps(outer: 0, inner: 0)) -> Bool {
        let layout = TileLayout(name: "Maximize", frames: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        return !tile([window], layout: layout, in: area, gaps: gaps).isEmpty
    }

    /// The window's frame in Cocoa screen coordinates, or nil when its app will not say.
    static func frame(of window: ManagedWindow) -> NSRect? {
        guard let element = window.element, let frame = currentFrame(of: element) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Puts a window back where it was, in Cocoa screen coordinates.
    static func restore(_ window: ManagedWindow, to frame: NSRect) {
        guard let element = window.element else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        setFrame(target, of: element, window: window)
    }

    /// Brings the tiled windows forward together, so none of them is left behind another app.
    static func raise(_ windows: [ManagedWindow]) {
        for window in windows.reversed() {
            window.element?.perform(kAXRaiseAction)
        }
    }
}
