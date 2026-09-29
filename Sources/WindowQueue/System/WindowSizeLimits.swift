import AppKit
import ApplicationServices

/// The sizes a window accepts: a minimum, a maximum, and for windows that keep their proportions
/// (the iOS Simulator) an aspect ratio. A fixed-size window has the minimum equal to the maximum.
struct SizeLimits: Equatable {
    var min: CGSize = .zero
    var max = CGSize(width: CGFloat.infinity, height: .infinity)
    /// Width over height of the part of the window that keeps its proportions: the frame less
    /// `chrome` points of title bar or toolbar on top.
    var aspect: CGFloat?
    var chrome: CGFloat = 0

    static let none = SizeLimits()

    static func fixed(_ size: CGSize) -> SizeLimits {
        SizeLimits(min: size, max: size)
    }

    var isFixed: Bool { min == max }
    var isNone: Bool { self == .none }

    /// The biggest size the window takes inside `box`. It comes out bigger than the box only when
    /// the window's minimum is.
    func fitted(in box: CGSize) -> CGSize {
        var width = clamp(box.width, min.width, max.width)
        var height = clamp(box.height, min.height, max.height)
        if let aspect, !isFixed, height > chrome {
            if width / (height - chrome) > aspect {
                width = Swift.max((height - chrome) * aspect, min.width)
            } else {
                height = Swift.max(width / aspect + chrome, min.height)
            }
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// The extents the window can take along one axis, given how much room it has along the other.
    func range(horizontal: Bool, across: CGFloat) -> ClosedRange<CGFloat> {
        let low = horizontal ? min.width : min.height
        var high = horizontal ? max.width : max.height
        if let aspect, !isFixed {
            let fit = horizontal ? Swift.max(across - chrome, 0) * aspect : across / aspect + chrome
            high = Swift.min(high, fit)
        }
        return low...Swift.max(low, high)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, low), high)
    }

    /// Reads the limits off where the window landed when asked for a few sizes, all within `area`:
    /// the smallest possible, the whole area, and a wide and a tall half of it.
    ///
    /// Nil when the window moved for none of them — its app resizes later, if at all, so nothing can
    /// be read from it.
    static func infer(tiny: CGSize, full: CGSize, wide: CGSize, tall: CGSize, area: CGSize) -> SizeLimits? {
        if tiny.approximatelyEquals(full) && wide.approximatelyEquals(tall) && tiny.approximatelyEquals(wide) {
            return nil
        }
        var limits = SizeLimits(min: tiny)

        // Two shapes that both lost space, at one proportion once a fixed height is taken off, and
        // the full-area answer at that proportion too: the window keeps its aspect ratio.
        if abs(wide.width - tall.width) > 2 {
            let chrome = (tall.width * wide.height - wide.width * tall.height) / (tall.width - wide.width)
            if chrome >= -1, chrome <= 150, wide.height - chrome > 1, full.height - chrome > 1 {
                let aspect = wide.width / (wide.height - chrome)
                let check = full.width / (full.height - chrome)
                let shrunk = !wide.approximatelyEquals(CGSize(width: area.width, height: area.height / 2))
                    && !tall.approximatelyEquals(CGSize(width: area.width / 2, height: area.height))
                if shrunk, abs(check - aspect) / aspect < 0.03 {
                    limits.aspect = aspect
                    limits.chrome = Swift.max(chrome, 0).rounded()
                    return limits
                }
            }
        }
        if full.width < area.width - 2 { limits.max.width = full.width }
        if full.height < area.height - 2 { limits.max.height = full.height }
        return limits
    }
}

extension CGSize {
    func approximatelyEquals(_ other: CGSize) -> Bool {
        abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}

/// Learns and remembers each window's `SizeLimits`.
///
/// The Accessibility API has no attribute for a window's minimum, maximum or aspect ratio, but
/// AppKit enforces all three the moment a size is set through it, so a window asked for a few sizes
/// shows them by where it lands. That flickers, so it is done only for windows that already refused
/// a frame WindowQueue gave them, and remembered. A window whose size cannot be set at all is
/// fixed at the size it has.
enum WindowSizeLimits {
    private static var known: [CGWindowID: SizeLimits] = [:]
    /// Windows that answered no probe: their apps resize later, so they cannot be read.
    private static var unreadable: Set<CGWindowID> = []
    /// When each window was last probed. A window that refuses a frame again soon after has limits
    /// the probe cannot describe; asking again would only flicker it on every tiling.
    private static var probedAt: [CGWindowID: Date] = [:]

    /// What is known about the window without resizing it.
    static func limits(of window: ManagedWindow, element: AXUIElement) -> SizeLimits {
        var settable = DarwinBoolean(true)
        if AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success,
           !settable.boolValue, let size = size(of: element) {
            return .fixed(size)
        }
        return known[window.id] ?? .none
    }

    static func canProbe(_ window: ManagedWindow) -> Bool {
        guard !unreadable.contains(window.id) else { return false }
        return probedAt[window.id].map { Date().timeIntervalSince($0) > 60 } ?? true
    }

    /// Asks the window for sizes within `area` (accessibility coordinates) and remembers the limits
    /// that shows. Runs inside the caller's frame change, which puts the window where it belongs next.
    @discardableResult
    static func probe(_ window: ManagedWindow, element: AXUIElement, area: CGRect) -> SizeLimits? {
        var origin = area.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            element.setAttribute(kAXPositionAttribute, value: value)
        }
        func landing(_ asked: CGSize) -> CGSize? {
            var size = asked
            guard let value = AXValueCreate(.cgSize, &size) else { return nil }
            element.setAttribute(kAXSizeAttribute, value: value)
            return self.size(of: element)
        }
        probedAt[window.id] = Date()
        let whole = area.size
        guard let tiny = landing(CGSize(width: 1, height: 1)),
              let full = landing(whole),
              let wide = landing(CGSize(width: whole.width, height: (whole.height / 2).rounded())),
              let tall = landing(CGSize(width: (whole.width / 2).rounded(), height: whole.height))
        else { return nil }
        guard let limits = SizeLimits.infer(tiny: tiny, full: full, wide: wide, tall: tall, area: whole) else {
            unreadable.insert(window.id)
            Diagnostics.note("size limits: \(window.appName) id=\(window.id) did not resize while probed")
            return nil
        }
        known[window.id] = limits
        Diagnostics.note("size limits: \(window.appName) id=\(window.id) min=\(limits.min) max=\(limits.max)"
            + (limits.aspect.map { " aspect=\($0) chrome=\(limits.chrome)" } ?? ""))
        return limits
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let value = element.attribute(kAXSizeAttribute, as: AXValue.self) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}

/// Shares a tiling area out among windows with size limits: a window that cannot grow gives its
/// room to its neighbours, one that cannot shrink takes it from them, and each window is centred in
/// what it gets.
///
/// Works on layouts made of straight cuts across the whole area — columns, rows, main and stack,
/// grid — by splitting them back into those cuts; any other layout keeps its cells as they are.
enum TileSolver {
    private indirect enum Node {
        case leaf(Int)
        case split(horizontal: Bool, children: [Node], weights: [CGFloat])
    }

    /// - Parameters:
    ///   - units: the layout's unit rects, origin top left.
    ///   - area: the room to share, in the same coordinates as the result.
    ///   - inset: room each cell leaves on every side, the half gap between windows.
    /// - Returns: each window's frame.
    static func frames(units: [CGRect], limits: [SizeLimits], in area: CGRect, inset: CGFloat) -> [CGRect] {
        let cells: [CGRect]
        if let root = node(Array(units.indices), units) {
            var solved = [CGRect](repeating: .zero, count: units.count)
            place(root, in: area, limits: limits, inset: inset, into: &solved)
            cells = solved
        } else {
            cells = units.map {
                CGRect(x: area.minX + $0.minX * area.width, y: area.minY + $0.minY * area.height,
                       width: $0.width * area.width, height: $0.height * area.height)
            }
        }
        return zip(cells, limits).map { cell, limits in
            let room = cell.insetBy(dx: inset, dy: inset)
            let size = limits.fitted(in: room.size)
            return CGRect(x: (room.midX - size.width / 2).rounded(), y: (room.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        }
    }

    private static func node(_ indices: [Int], _ units: [CGRect]) -> Node? {
        if indices.count == 1 { return .leaf(indices[0]) }
        for horizontal in [true, false] {
            let groups = cut(indices, units, horizontal: horizontal)
            guard groups.count > 1 else { continue }
            var children: [Node] = []
            for group in groups {
                guard let child = node(group, units) else { return nil }
                children.append(child)
            }
            let weights = groups.map { group -> CGFloat in
                let low = group.map { horizontal ? units[$0].minX : units[$0].minY }.min() ?? 0
                let high = group.map { horizontal ? units[$0].maxX : units[$0].maxY }.max() ?? 0
                return high - low
            }
            return .split(horizontal: horizontal, children: children, weights: weights)
        }
        return nil
    }

    /// The cells in bands along one axis, split wherever a line crosses no cell.
    private static func cut(_ indices: [Int], _ units: [CGRect], horizontal: Bool) -> [[Int]] {
        let low = { (i: Int) in horizontal ? units[i].minX : units[i].minY }
        let high = { (i: Int) in horizontal ? units[i].maxX : units[i].maxY }
        var groups: [[Int]] = []
        var reach = -CGFloat.infinity
        for i in indices.sorted(by: { low($0) < low($1) }) {
            if low(i) >= reach - 1e-6 {
                groups.append([i])
            } else {
                groups[groups.count - 1].append(i)
            }
            reach = max(reach, high(i))
        }
        return groups
    }

    private static func range(_ node: Node, horizontal: Bool, across: CGFloat,
                              limits: [SizeLimits], inset: CGFloat) -> ClosedRange<CGFloat> {
        switch node {
        case .leaf(let i):
            let range = limits[i].range(horizontal: horizontal, across: across - 2 * inset)
            return (range.lowerBound + 2 * inset)...(range.upperBound + 2 * inset)
        case let .split(splitHorizontal, children, weights):
            let total = weights.reduce(0, +)
            if splitHorizontal == horizontal {
                let ranges = children.map { range($0, horizontal: horizontal, across: across, limits: limits, inset: inset) }
                let low = ranges.map(\.lowerBound).reduce(0, +)
                return low...max(low, ranges.map(\.upperBound).reduce(0, +))
            }
            // Side by side the other way: all share this extent, each with its share of the other.
            let ranges = zip(children, weights).map {
                range($0, horizontal: horizontal, across: across * $1 / total, limits: limits, inset: inset)
            }
            let low = ranges.map(\.lowerBound).max() ?? 0
            return low...max(low, ranges.map(\.upperBound).min() ?? .infinity)
        }
    }

    private static func place(_ node: Node, in rect: CGRect, limits: [SizeLimits], inset: CGFloat,
                              into frames: inout [CGRect]) {
        switch node {
        case .leaf(let i):
            frames[i] = rect
        case let .split(horizontal, children, weights):
            let across = horizontal ? rect.height : rect.width
            let ranges = children.map { range($0, horizontal: horizontal, across: across, limits: limits, inset: inset) }
            let extents = share(horizontal ? rect.width : rect.height, ranges: ranges, weights: weights)
            var start = horizontal ? rect.minX : rect.minY
            for (child, extent) in zip(children, extents) {
                let end = (start + extent).rounded()
                let part = horizontal
                    ? CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
                    : CGRect(x: rect.minX, y: start, width: rect.width, height: end - start)
                place(child, in: part, limits: limits, inset: inset, into: &frames)
                start = end
            }
        }
    }

    /// Splits `total` in proportion to the weights as far as each range allows.
    static func share(_ total: CGFloat, ranges: [ClosedRange<CGFloat>], weights: [CGFloat]) -> [CGFloat] {
        let lows = ranges.map(\.lowerBound)
        let highs = ranges.map(\.upperBound)
        let lowSum = lows.reduce(0, +)
        // Not enough room for everyone's minimum: shrink them all alike and let the windows overlap.
        if lowSum >= total {
            return lowSum > 0 ? lows.map { $0 * total / lowSum } : weights.map { _ in total / CGFloat(weights.count) }
        }
        // More room than all can use: hand out the rest evenly; the windows are centred in it.
        let highSum = highs.reduce(0, +)
        if highSum <= total {
            let spare = (total - highSum) / CGFloat(ranges.count)
            return highs.map { $0 + spare }
        }
        let weightSum = weights.reduce(0, +)
        func sizes(_ scale: CGFloat) -> [CGFloat] {
            zip(ranges, weights).map { min(max($1 / weightSum * scale, $0.lowerBound), $0.upperBound) }
        }
        var low: CGFloat = 0
        var high = total * max(1, weightSum) * 1000
        for _ in 0..<80 {
            let mid = (low + high) / 2
            if sizes(mid).reduce(0, +) < total { low = mid } else { high = mid }
        }
        return sizes(high)
    }
}
