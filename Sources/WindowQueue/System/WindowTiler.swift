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
        let bounds = CGRect(x: area.minX, y: top, width: area.width, height: area.height)
        let members = zip(windows, layout.frames).compactMap { window, unit in
            window.element.map { (window: window, element: $0, unit: unit) }
        }
        var limits = members.map {
            respectsSizeLimits ? WindowSizeLimits.limits(of: $0.window, element: $0.element) : .none
        }

        func frames() -> [CGRect] {
            guard limits.allSatisfy(\.isNone) else {
                return TileSolver.frames(units: members.map(\.unit), limits: limits, in: bounds, inset: gaps.inner / 2)
            }
            return members.map { member in
                let unit = member.unit
                let cell = CGRect(x: (area.minX + unit.minX * area.width).rounded(),
                                  y: (top + unit.minY * area.height).rounded(),
                                  width: (unit.width * area.width).rounded(),
                                  height: (unit.height * area.height).rounded())
                return cell.insetBy(dx: gaps.inner / 2, dy: gaps.inner / 2)
            }
        }

        var planned = frames()
        var refused: [Int] = []
        for (index, member) in members.enumerated() {
            if member.window.isMinimized {
                member.element.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
            }
            let landed = setFrame(planned[index], of: member.element, window: member.window)
            if respectsSizeLimits, let landed, !landed.size.approximatelyEquals(planned[index].size),
               WindowSizeLimits.canProbe(member.window) {
                refused.append(index)
            }
        }
        // A window that would not take its size shows what it takes instead, and the others make
        // room for that.
        if !refused.isEmpty {
            for index in refused {
                let member = members[index]
                withoutAnimation(pid: member.window.pid) {
                    WindowSizeLimits.probe(member.window, element: member.element, area: bounds)
                }
                limits[index] = WindowSizeLimits.limits(of: member.window, element: member.element)
            }
            planned = frames()
            for (index, member) in members.enumerated() {
                setFrame(planned[index], of: member.element, window: member.window)
            }
        }
        let placed = members.map(\.window)
        Diagnostics.note("tiled \(placed.count)/\(windows.count) windows as \(layout.name)")
        return placed
    }

    /// Fit windows to the sizes they accept — minimum, maximum, fixed size, aspect ratio — instead
    /// of giving each its cell regardless. `Preferences.respectWindowSizeLimits`.
    static var respectsSizeLimits = true

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

    /// - Returns: where the window landed straight away.
    @discardableResult
    private static func setFrame(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow) -> CGRect? {
        lastRequest += 1
        currentRequest[window.id] = lastRequest
        placedFrames[window.id] = frame
        return apply(frame, of: element, window: window, request: lastRequest, check: 0)
    }

    @discardableResult
    private static func apply(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow,
                              request: Int, check: Int) -> CGRect? {
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return nil }
        var landed: CGRect?
        withoutAnimation(pid: window.pid) {
            // Move first, then resize: one pass, and the window is never drawn at the new size in
            // the old place, which reads as a flicker.
            element.setAttribute(kAXPositionAttribute, value: originValue)
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
            // Apps that clamp a resize against where the window was need the other order, but only
            // those: asking for it every time is what caused the flicker.
            landed = currentFrame(of: element)
            guard let first = landed, !matches(first, frame) else { return }
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
            element.setAttribute(kAXPositionAttribute, value: originValue)
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
            landed = currentFrame(of: element)
        }

        scheduleCheck(frame, of: element, window: window, request: request, check: check, seen: nil)
        return landed
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

    /// The window's frame as the WindowServer has it, in Cocoa screen coordinates. Unlike the
    /// accessibility frame it needs no element, and it is always the frame of this very window —
    /// an element kept from earlier can belong to a window that has since been replaced, as a tab
    /// that went behind another is.
    static func serverFrame(of id: CGWindowID) -> NSRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Windows on screen right now, on any display.
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
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
            (window.element ?? WindowSpaceMover.element(for: window))?.perform(kAXRaiseAction)
        }
    }

    /// Those of `ids` that some other ordinary window overlaps from in front. A window in the
    /// queue (`queued`) always counts, whichever app it belongs to — another Chrome window over the
    /// tiled one buries it as surely as any other app's. Other windows of the apps in `ownPIDs` do
    /// not: an app's own popovers, palettes and dialogs belong on top of it.
    static func coveredWindowIDs(among ids: Set<CGWindowID>, ownPIDs: Set<pid_t>,
                                 queued: Set<CGWindowID>) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return coveredWindowIDs(among: ids, in: list, ownPIDs: ownPIDs, queued: queued,
                                selfPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// The same, over a window list as `CGWindowListCopyWindowInfo` gives it, front to back.
    static func coveredWindowIDs(among ids: Set<CGWindowID>, in list: [[String: Any]], ownPIDs: Set<pid_t>,
                                 queued: Set<CGWindowID>, selfPID: pid_t) -> Set<CGWindowID> {
        var covered = Set<CGWindowID>()
        var above: [CGRect] = []
        // Front to back: every ordinary window met before one of `ids` is in front of it.
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if ids.contains(number) {
                // A sliver — a shadow's edge, a gap's worth of a neighbour — does not bury a window.
                if above.contains(where: { let hit = $0.intersection(bounds); return hit.width > 8 && hit.height > 8 }) {
                    covered.insert(number)
                }
            } else if (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != selfPID,
                      queued.contains(number) || !ownPIDs.contains(owner) {
                above.append(bounds)
            }
        }
        return covered
    }
}
