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
        let holds = respectsSizeLimits && showsPlaceholders && members.count > 1

        func plan() -> TileSolver.Plan {
            guard limits.allSatisfy(\.isNone) else {
                return TileSolver.plan(units: members.map(\.unit), limits: limits, in: bounds,
                                       inset: gaps.inner / 2, holdOversized: holds)
            }
            let frames = members.map { member in
                let unit = member.unit
                let cell = CGRect(x: (area.minX + unit.minX * area.width).rounded(),
                                  y: (top + unit.minY * area.height).rounded(),
                                  width: (unit.width * area.width).rounded(),
                                  height: (unit.height * area.height).rounded())
                return cell.insetBy(dx: gaps.inner / 2, dy: gaps.inner / 2)
            }
            return TileSolver.Plan(rooms: frames, frames: frames)
        }

        var planned = plan()
        // A window that would not take its size shows what it takes instead, and the others make
        // room for that. Making room can squeeze a neighbour below its own limits in turn, so the
        // layout is made again while that teaches something new, a few times at most.
        for pass in 0..<3 {
            var refused: [Int] = []
            var learnt = false
            for (index, member) in members.enumerated() {
                if pass == 0, member.window.isMinimized {
                    member.element.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
                }
                let asked = planned.frames[index].size
                // A window just taken to another display is clamped to the old one for a moment:
                // that is not the window's limit, and the checks set its size again.
                guard let landed = setFrame(planned.frames[index], of: member.element, window: member.window),
                      respectsSizeLimits, !landed.size.approximatelyEquals(asked),
                      !isCrossingDisplays(member.window.id)
                else { continue }
                if WindowSizeLimits.canProbe(member.window) {
                    refused.append(index)
                } else if WindowSizeLimits.isReadable(member.window),
                          WindowSizeLimits.learn(member.window, asked: asked, landed: landed.size) {
                    // Probed moments ago, and refused again all the same: what it took instead says more.
                    limits[index] = WindowSizeLimits.limits(of: member.window, element: member.element)
                    learnt = true
                }
            }
            guard !refused.isEmpty || learnt else { break }
            for index in refused {
                let member = members[index]
                withoutAnimation(pid: member.window.pid) {
                    WindowSizeLimits.probe(member.window, element: member.element, area: bounds)
                }
                limits[index] = WindowSizeLimits.limits(of: member.window, element: member.element)
            }
            planned = plan()
            if pass == 2 {
                for (index, member) in members.enumerated() {
                    setFrame(planned.frames[index], of: member.element, window: member.window)
                }
            }
        }
        // Each window's room in the layout, which may be larger than the window (an app with a
        // largest size or a fixed shape is centred in it): what a hand resize moves.
        for (index, member) in members.enumerated() { placedRooms[member.window.id] = planned.rooms[index] }
        // Those that still do not fit, however small the others go, are held out: a placeholder
        // takes their place in the layout.
        TilePlaceholders.shared.set(members.indices.map { index in
            let room = planned.rooms[index]
            let held = planned.held.contains(index)
            if held {
                Diagnostics.note("tiling: \(members[index].window.appName) id=\(members[index].window.id) "
                    + "does not fit \(room.size), placeholder stands in")
            }
            return (window: members[index].window, limits: limits[index],
                    room: held ? NSRect(x: room.minX, y: primaryHeight - room.maxY,
                                        width: room.width, height: room.height) : nil)
        })
        let placed = members.map(\.window)
        Diagnostics.note("tiled \(placed.count)/\(windows.count) windows as \(layout.name)")
        return placed
    }

    /// Fit windows to the sizes they accept — minimum, maximum, fixed size, aspect ratio — instead
    /// of giving each its cell regardless. `Preferences.respectWindowSizeLimits`.
    static var respectsSizeLimits = true

    /// Put a placeholder in the place of a window too big for it, rather than let it overlap its
    /// neighbours. `Preferences.tilePlaceholders`.
    static var showsPlaceholders = true

    /// A window settled, a while after it was placed, at another size than it was asked for, and
    /// that told something new about its limits: the layout it is in wants making again.
    static var onLateRefusal: ((CGWindowID) -> Void)?

    /// The frame request each window is currently following. A window told to go somewhere else —
    /// maximized and then restored, say — must not have the older request put back underneath it.
    private static var currentRequest: [CGWindowID: Int] = [:]
    /// The frame each window was last given, so nothing else corrects a window we just placed.
    private(set) static var placedFrames: [CGWindowID: CGRect] = [:]
    /// Each tiled window's room in its layout, in accessibility coordinates.
    private(set) static var placedRooms: [CGWindowID: CGRect] = [:]
    private static var lastRequest = 0

    /// When to look at a tiled window again. A window that has just arrived from another
    /// workspace, or whose app animates or snaps its own frame, can accept a size and then lose the
    /// position, so the whole frame is checked a few times and set again whenever it slipped.
    private static let checkDelays: [TimeInterval] = [0.15, 0.4, 0.8, 1.5]

    /// - Returns: where the window landed straight away.
    @discardableResult
    private static func setFrame(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow) -> CGRect? {
        lastRequest += 1
        if let previous = currentRequest[window.id] { crossingRequests.remove(previous) }
        currentRequest[window.id] = lastRequest
        placedFrames[window.id] = frame
        if let from = currentFrame(of: element), let source = screenIndex(ofAX: from),
           let target = screenIndex(ofAX: frame), source != target {
            crossingRequests.insert(lastRequest)
        }
        return apply(frame, of: element, window: window, request: lastRequest, check: 0)
    }

    /// Requests that take a window over to another display. An app learns which display its
    /// window is on only a moment after it gets there, and until then clamps a new size to the old
    /// one (Chrome does): a size refused then says nothing about the window's limits, and the size
    /// has to be asked again once the app has caught up.
    private static var crossingRequests: Set<Int> = []

    /// Whether the window's latest frame request takes it to another display.
    static func isCrossingDisplays(_ id: CGWindowID) -> Bool {
        currentRequest[id].map(crossingRequests.contains) ?? false
    }

    /// The screen holding most of a rect in accessibility coordinates, by its place in `NSScreen.screens`.
    private static func screenIndex(ofAX rect: CGRect) -> Int? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        let overlaps = NSScreen.screens.map { screen -> CGFloat in
            let common = screen.frame.intersection(cocoa)
            return common.isNull ? 0 : common.width * common.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { return nil }
        return best
    }

    @discardableResult
    private static func apply(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow,
                              request: Int, check: Int, refusal: CGSize? = nil) -> CGRect? {
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
        if crossingRequests.contains(request), let first = landed, !matches(first, frame) {
            // Arrived on another display with the size clamped to the old one: ask again as soon as
            // the app has noticed where its window went, well before the regular checks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard currentRequest[window.id] == request,
                      let current = currentFrame(of: element), !matches(current, frame) else { return }
                withoutAnimation(pid: window.pid) {
                    element.setAttribute(kAXSizeAttribute, value: sizeValue)
                    element.setAttribute(kAXPositionAttribute, value: originValue)
                    element.setAttribute(kAXSizeAttribute, value: sizeValue)
                }
            }
        }

        scheduleCheck(frame, of: element, window: window, request: request, check: check, seen: nil,
                      refusal: refusal)
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

    /// - Parameters:
    ///   - seen: where the window was at the previous check, so a frame still on its way is left
    ///     to arrive instead of being fought mid-flight.
    ///   - refusal: the size the window settled at instead the last time it was set again.
    private static func scheduleCheck(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow,
                                      request: Int, check: Int, seen: CGRect?, refusal: CGSize? = nil) {
        guard checkDelays.indices.contains(check) else { return }
        let wait = checkDelays[check] - (check == 0 ? 0 : checkDelays[check - 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            // A newer frame request has taken this window over.
            guard currentRequest[window.id] == request, let current = currentFrame(of: element) else { return }
            if matches(current, frame) {
                scheduleCheck(frame, of: element, window: window, request: request, check: check + 1,
                              seen: current, refusal: refusal)
                return
            }
            guard let seen, matches(current, seen) else {
                // Still moving: look again before deciding it went wrong.
                scheduleCheck(frame, of: element, window: window, request: request, check: check + 1,
                              seen: current, refusal: refusal)
                return
            }
            // Twice at the same wrong size, set again in between: that is the size it takes. An app
            // that resizes late cannot be probed, so this is where its limits are learnt.
            if respectsSizeLimits, !crossingRequests.contains(request), let refusal,
               current.size.approximatelyEquals(refusal),
               NSEvent.pressedMouseButtons == 0,
               WindowSizeLimits.learn(window, asked: frame.size, landed: current.size) {
                onLateRefusal?(window.id)
                return
            }
            Diagnostics.note("tiling: \(window.appName) id=\(window.id) settled at \(current), setting \(frame) again")
            let size = current.size.approximatelyEquals(frame.size) ? nil : current.size
            apply(frame, of: element, window: window, request: request, check: check + 1, refusal: size)
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

    /// The window's room in the layout it was last tiled into, in Cocoa screen coordinates.
    static func placedRoom(of id: CGWindowID) -> NSRect? {
        guard let room = placedRooms[id] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: room.minX, y: primaryHeight - room.maxY, width: room.width, height: room.height)
    }

    /// The frame WindowQueue last asked of the window, in Cocoa screen coordinates.
    static func placedFrame(of id: CGWindowID) -> NSRect? {
        guard let frame = placedFrames[id] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Sets a window's frame once, in Cocoa screen coordinates, with no checks or retries: for a
    /// window following a neighbour being resized, where the next drag step soon asks again.
    /// - Returns: where it landed, in Cocoa screen coordinates.
    @discardableResult
    static func nudge(_ window: ManagedWindow, to frame: NSRect) -> NSRect? {
        guard let element = window.element else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        placedFrames[window.id] = target
        currentRequest[window.id] = nil
        var size = target.size
        var origin = target.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return nil }
        withoutAnimation(pid: window.pid) {
            // Shrinking towards the far edge needs the size first, growing the position first;
            // setting the size on both sides covers either way in one go.
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
            element.setAttribute(kAXPositionAttribute, value: originValue)
            element.setAttribute(kAXSizeAttribute, value: sizeValue)
        }
        guard let landed = currentFrame(of: element) else { return nil }
        return NSRect(x: landed.minX, y: primaryHeight - landed.maxY, width: landed.width, height: landed.height)
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

/// How a tiled window's frame changed since it was placed. Resizing a window by an edge or corner
/// keeps the opposite edges where they were; moving it shifts every edge. Only a move takes the
/// window out of its layout.
enum TiledFrameChange: Equatable {
    case unchanged, resized, moved

    /// How far the edge held still in a resize may slip with an app rounding its size.
    static let snapTolerance: CGFloat = 32

    /// - Parameter sizeTolerance: how much the size may change and still be the same; smaller
    ///   while the user is at the mouse, when any resize must be followed.
    static func between(_ placed: NSRect, _ now: NSRect, tolerance: CGFloat = 4,
                        sizeTolerance: CGFloat? = nil) -> TiledFrameChange {
        func same(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        let sizeTolerance = sizeTolerance ?? tolerance
        let sameSize = abs(now.width - placed.width) <= sizeTolerance && abs(now.height - placed.height) <= sizeTolerance
        if sameSize && same(now.minX, placed.minX) && same(now.minY, placed.minY) { return .unchanged }
        if sameSize { return .moved }
        // An app that keeps to a grid (a terminal's rows and columns of text) rounds its size as it
        // is resized, and the edge being held can slip by a character or two with it.
        func kept(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= snapTolerance }
        let keepsHorizontalEdge = kept(now.minX, placed.minX) || kept(now.maxX, placed.maxX)
        let keepsVerticalEdge = kept(now.minY, placed.minY) || kept(now.maxY, placed.maxY)
        return keepsHorizontalEdge && keepsVerticalEdge ? .resized : .moved
    }
}

/// When one window of a layout is resized, the windows sharing the edges it dragged follow them:
/// a neighbour across the edge gives up or takes the room, and a window lined up along the same
/// divider (the other row of a grid, say) moves its edge too, so the layout stays one piece.
enum TiledResize {
    /// Narrower or shorter than this, a neighbour stops giving way.
    static let minimumSide: CGFloat = 120

    /// - Parameters:
    ///   - old: where the resized window was. - new: where it is now.
    ///   - others: the other windows of the layout and their frames.
    ///   - gap: the room left between windows of the layout.
    /// - Returns: the new frames of the windows that have to follow; the rest stay as they are.
    static func follow(from old: NSRect, to new: NSRect, others: [CGWindowID: NSRect],
                       gap: CGFloat, tolerance: CGFloat = 24) -> [CGWindowID: NSRect] {
        // The tolerance is generous: terminals keep to whole rows and columns of text, so their
        // edges sit up to a character short of where the layout put them.
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        // Any change of a dragged edge counts, however small; the tolerance is for finding the
        // neighbours, whose edges may sit off the line.
        func moved(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.5 }
        /// Whether `edge` of a neighbour faces the dragged edge at `at` across the gap. `ahead` says
        /// the neighbour lies on the far side (beyond a max edge), else on the near side.
        func faces(_ edge: CGFloat, _ at: CGFloat, ahead: Bool) -> Bool {
            let distance = ahead ? edge - at : at - edge
            return distance >= -tolerance && distance <= gap + tolerance
        }
        var result: [CGWindowID: NSRect] = [:]
        for (id, frame) in others {
            var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
            if moved(old.maxX, new.maxX) {
                if faces(frame.minX, old.maxX, ahead: true) { minX = new.maxX + gap }
                else if near(frame.maxX, old.maxX) { maxX = new.maxX }
            }
            if moved(old.minX, new.minX) {
                if faces(frame.maxX, old.minX, ahead: false) { maxX = new.minX - gap }
                else if near(frame.minX, old.minX) { minX = new.minX }
            }
            if moved(old.maxY, new.maxY) {
                if faces(frame.minY, old.maxY, ahead: true) { minY = new.maxY + gap }
                else if near(frame.maxY, old.maxY) { maxY = new.maxY }
            }
            if moved(old.minY, new.minY) {
                if faces(frame.maxY, old.minY, ahead: false) { maxY = new.minY - gap }
                else if near(frame.minY, old.minY) { minY = new.minY }
            }
            // A neighbour squeezed past its smallest keeps the far edge and stops there.
            if maxX - minX < minimumSide {
                if minX != frame.minX { minX = maxX - minimumSide } else { maxX = minX + minimumSide }
            }
            if maxY - minY < minimumSide {
                if minY != frame.minY { minY = maxY - minimumSide } else { maxY = minY + minimumSide }
            }
            let moved = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if moved != frame { result[id] = moved }
        }
        return result
    }

    /// Where a following window goes when its app will not take the size asked (a minimum of its
    /// own): it keeps the size it insists on and stays against its far edge, the one the drag did
    /// not reach, instead of being pushed past it (off the screen, even).
    ///
    /// One that came out smaller (a terminal rounding to whole rows) stays against the edge that
    /// moved instead, so it keeps touching the divider and the spare room goes to the far side.
    static func anchor(asked: NSRect, landed size: NSSize, start: NSRect) -> NSRect {
        /// - Parameter top: where it sits when neither edge moved (left, or top in Cocoa terms).
        func origin(_ lo: CGFloat, _ hi: CGFloat, _ startLo: CGFloat, _ startHi: CGFloat,
                    _ length: CGFloat, _ cell: CGFloat, top: Bool) -> CGFloat {
            let movedLo = abs(lo - startLo) > 0.5, movedHi = abs(hi - startHi) > 0.5
            let bigger = length > cell + 0.5
            if movedLo != movedHi {
                // Bigger: keep the edge that did not move. Smaller: keep the one that did.
                return movedLo == bigger ? hi - length : lo
            }
            return top ? hi - length : lo
        }
        let x = origin(asked.minX, asked.maxX, start.minX, start.maxX, size.width, asked.width, top: false)
        let y = origin(asked.minY, asked.maxY, start.minY, start.maxY, size.height, asked.height, top: true)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where the dragged window has to stop so it does not cover a neighbour that could not give way
    /// any further (our smallest side, or the app's own minimum).
    /// - Parameters:
    ///   - mates: each following window's frame when the drag began and where it is now.
    static func clamp(_ dragged: NSRect, start: NSRect, mates: [(start: NSRect, now: NSRect)],
                      gap: CGFloat, tolerance: CGFloat = 24) -> NSRect {
        func faces(_ edge: CGFloat, _ at: CGFloat, ahead: Bool) -> Bool {
            let distance = ahead ? edge - at : at - edge
            return distance >= -tolerance && distance <= gap + tolerance
        }
        func aligned(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        // An edge pushed outwards squeezes the windows across it: one that stopped short holds it
        // back. An edge pulled inwards squeezes the windows lined up along the same divider: one of
        // those that stopped short holds it back. (The others simply follow, and limit nothing.)
        // Which way each edge went is read from the drag, not from the limits applied so far: the
        // result must not depend on the order the mates come in.
        let grewRight = dragged.maxX > start.maxX, shrankRight = dragged.maxX < start.maxX
        let grewLeft = dragged.minX < start.minX, shrankLeft = dragged.minX > start.minX
        let grewUp = dragged.maxY > start.maxY, shrankUp = dragged.maxY < start.maxY
        let grewDown = dragged.minY < start.minY, shrankDown = dragged.minY > start.minY
        var minX = dragged.minX, maxX = dragged.maxX, minY = dragged.minY, maxY = dragged.maxY
        for mate in mates {
            if grewRight, faces(mate.start.minX, start.maxX, ahead: true) { maxX = min(maxX, mate.now.minX - gap) }
            if shrankRight, aligned(mate.start.maxX, start.maxX) { maxX = max(maxX, mate.now.maxX) }
            if grewLeft, faces(mate.start.maxX, start.minX, ahead: false) { minX = max(minX, mate.now.maxX + gap) }
            if shrankLeft, aligned(mate.start.minX, start.minX) { minX = min(minX, mate.now.minX) }
            if grewUp, faces(mate.start.minY, start.maxY, ahead: true) { maxY = min(maxY, mate.now.minY - gap) }
            if shrankUp, aligned(mate.start.maxY, start.maxY) { maxY = max(maxY, mate.now.maxY) }
            if grewDown, faces(mate.start.maxY, start.minY, ahead: false) { minY = max(minY, mate.now.maxY + gap) }
            if shrankDown, aligned(mate.start.minY, start.minY) { minY = min(minY, mate.now.minY) }
        }
        return NSRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }
}
