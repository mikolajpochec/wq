import AppKit

/// The decisions behind the monitor shortcuts, worked out on plain values so they can be followed
/// without real displays: which monitor a shortcut goes to, where a window lands there, and which
/// window takes the focus. `AppDelegate` measures the screens and carries the plans out.
enum MonitorPlanner {
    /// One connected display.
    struct Display: Equatable {
        let id: CGDirectDisplayID
        /// The whole screen, in Cocoa coordinates (origin bottom-left of the primary display).
        let frame: NSRect
        /// The room windows are laid out in: the screen less menu bar, Dock and the strip's room.
        let area: NSRect
    }

    /// Displays left to right (top to bottom where they are stacked), the way the shortcuts count.
    static func ordered(_ displays: [Display]) -> [Display] {
        displays.sorted { isOrderedBefore($0.frame, $1.frame) }
    }

    /// The left to right order of `Monitors.orderedScreens`.
    static func isOrderedBefore(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        lhs.minX != rhs.minX ? lhs.minX < rhs.minX : lhs.maxY > rhs.maxY
    }

    /// The display holding most of a frame (Cocoa coordinates); nil when it is on none of them.
    static func index(holding frame: NSRect, in displays: [Display]) -> Int? {
        let overlaps = displays.map { overlap($0.frame, frame) }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0
        else { return nil }
        return best
    }

    static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let common = a.intersection(b)
        return common.isNull ? 0 : common.width * common.height
    }

    // MARK: - Which monitor

    enum Target: Equatable {
        /// A single display: there is nowhere else to go.
        case onlyOne
        /// The shortcut names a monitor that is not connected.
        case missing(number: Int, count: Int)
        /// The index into the ordered displays.
        case index(Int)
    }

    /// Monitor `number` (counted from 1, left to right), or with nil the one after `current`,
    /// going round all of them (never just between two).
    static func target(number: Int?, after current: Int?, count: Int) -> Target {
        guard count > 1 else { return .onlyOne }
        if let number {
            return (1...count).contains(number) ? .index(number - 1) : .missing(number: number, count: count)
        }
        let from = current.map { min(max($0, 0), count - 1) } ?? 0
        return .index((from + 1) % count)
    }

    // MARK: - Where a window lands

    /// The frame `WindowTiler.fill` gives a window: the area less the outer gap all round.
    static func filledFrame(in area: NSRect, gaps: WindowTiler.Gaps) -> NSRect {
        let frame = area.insetBy(dx: gaps.outer, dy: gaps.outer)
        return NSRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                      width: frame.width.rounded(), height: frame.height.rounded())
    }

    /// Near enough to the maximized frame to count as maximized; apps round and snap to their own
    /// grids, so an exact match would leave the shortcut one-way. Measured against what a maximize
    /// actually gives, outer gap included, or a gap over the tolerance would never count.
    static func fills(_ frame: NSRect, _ area: NSRect, gaps: WindowTiler.Gaps = .init(outer: 0, inner: 0)) -> Bool {
        let filled = area.insetBy(dx: gaps.outer, dy: gaps.outer)
        return abs(frame.minX - filled.minX) <= 12 && abs(frame.minY - filled.minY) <= 12
            && abs(frame.width - filled.width) <= 24 && abs(frame.height - filled.height) <= 24
    }

    /// A frame at the same place relative to another area, scaled to it and kept inside it.
    static func map(_ frame: NSRect, from source: NSRect, to target: NSRect) -> NSRect {
        let scaleX = source.width > 0 ? target.width / source.width : 1
        let scaleY = source.height > 0 ? target.height / source.height : 1
        var result = NSRect(x: target.minX + (frame.minX - source.minX) * scaleX,
                            y: target.minY + (frame.minY - source.minY) * scaleY,
                            width: min(frame.width * scaleX, target.width),
                            height: min(frame.height * scaleY, target.height))
        result.origin.x = min(max(result.minX, target.minX), target.maxX - result.width)
        result.origin.y = min(max(result.minY, target.minY), target.maxY - result.height)
        return result
    }

    /// Where a window goes on another screen: a maximized one fills it, any other keeps its place
    /// and size relative to the room each screen has.
    struct Landing: Equatable {
        var frame: NSRect
        /// It filled its screen and fills the new one (`WindowTiler.fill`, not a plain move).
        var fills: Bool
    }

    static func relocate(_ frame: NSRect, from source: NSRect, to target: NSRect,
                         gaps: WindowTiler.Gaps) -> Landing {
        fills(frame, source, gaps: gaps)
            ? Landing(frame: filledFrame(in: target, gaps: gaps), fills: true)
            : Landing(frame: map(frame, from: source, to: target), fills: false)
    }

    // MARK: - The frame the fullscreen shortcut puts back

    /// A window sent to another screen takes the frame remembered for it along, or undoing a
    /// maximize there would carry it back to the old screen.
    static func carried(_ stored: NSRect?, from source: NSRect, to target: NSRect) -> NSRect? {
        stored.map { map($0, from: source, to: target) }
    }

    /// The frame to put a window back to out of fullscreen: the one remembered, or, when that was
    /// on another screen than the window is now (dragged there, say), the same place on this one.
    /// One remembered on a screen since unplugged keeps its size, moved inside this screen's room.
    static func restoreFrame(_ stored: NSRect, current: NSRect, area: NSRect, displays: [Display]) -> NSRect {
        guard let old = index(holding: stored, in: displays) else { return kept(stored, inside: area) }
        guard let now = index(holding: current, in: displays), old != now else { return stored }
        return map(stored, from: displays[old].area, to: area)
    }

    /// A frame moved (and if need be shrunk) to lie inside an area.
    static func kept(_ frame: NSRect, inside area: NSRect) -> NSRect {
        let width = min(frame.width, area.width), height = min(frame.height, area.height)
        return NSRect(x: min(max(frame.minX, area.minX), area.maxX - width),
                      y: min(max(frame.minY, area.minY), area.maxY - height),
                      width: width, height: height)
    }

    // MARK: - Moving windows to a monitor

    struct Move: Equatable {
        let id: CGWindowID
        let from: Int
        let landing: Landing
    }

    enum MovePlan: Equatable {
        case onlyOne
        case missing(number: Int, count: Int)
        /// None of the windows could be measured.
        case nothing
        /// Every window is on that monitor already.
        case alreadyThere(target: Int)
        /// `lead` is where the first window was: the monitor frame flashes when the work changes
        /// monitor, judged by it.
        case move(target: Int, lead: Int, moves: [Move])
    }

    /// Sends windows (the first leads) to monitor `number`, or with nil to the one after the lead's.
    /// Frames are Cocoa coordinates, nil for a window that cannot be measured; displays ordered.
    static func planMove(_ windows: [(id: CGWindowID, frame: NSRect?)], toMonitor number: Int?,
                         displays: [Display], gaps: WindowTiler.Gaps) -> MovePlan {
        guard displays.count > 1 else { return .onlyOne }
        if let number, !(1...displays.count).contains(number) {
            return .missing(number: number, count: displays.count)
        }
        let measured: [(id: CGWindowID, frame: NSRect, source: Int)] = windows.compactMap { window in
            guard let frame = window.frame, let source = index(holding: frame, in: displays) else { return nil }
            return (window.id, frame, source)
        }
        guard let lead = measured.first,
              case .index(let target) = self.target(number: number, after: lead.source, count: displays.count)
        else { return .nothing }
        let moves = measured.filter { $0.source != target }.map {
            Move(id: $0.id, from: $0.source,
                 landing: relocate($0.frame, from: displays[$0.source].area, to: displays[target].area, gaps: gaps))
        }
        return moves.isEmpty ? .alreadyThere(target: target) : .move(target: target, lead: lead.source, moves: moves)
    }

    // MARK: - Focusing a monitor

    /// The window landed on when going to a monitor: the one on top there (`frontToBack` is the
    /// window server's on-screen order), else the first of the queue's there; nil leaves only the
    /// pointer to move.
    static func landing(among candidates: [CGWindowID], frontToBack: [CGWindowID]) -> CGWindowID? {
        let wanted = Set(candidates)
        return frontToBack.first(where: wanted.contains) ?? candidates.first
    }

    // MARK: - Coordinates

    /// Cocoa rect (origin bottom-left of the primary display, y up) to WindowServer/AX coordinates
    /// (origin top-left of the primary display, y down), and back: the same flip both ways.
    static func flipped(_ rect: NSRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The point the pointer is warped to for a screen: its middle, in WindowServer coordinates.
    static func warpPoint(for screen: NSRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: screen.midX, y: primaryHeight - screen.midY)
    }

    // MARK: - The strip's room

    /// A screen's room less what the strip keeps for itself on its side.
    static func stripReduced(_ area: NSRect, prefs: Preferences) -> NSRect {
        var area = area
        guard prefs.stripDisplay != .hidden, prefs.reserveScreenSpace else { return area }
        let gap = CGFloat(StripMetrics.reservedWidth(for: prefs))
        switch prefs.stripSide {
        case .left:
            area.origin.x += gap
            area.size.width -= gap
        case .right:
            area.size.width -= gap
        case .top:
            area.size.height -= gap
        case .bottom:
            area.origin.y += gap
            area.size.height -= gap
        }
        return area
    }
}
