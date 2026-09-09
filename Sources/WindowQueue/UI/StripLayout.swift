import AppKit
import SwiftUI

/// Where everything in the strip sits.
///
/// The strip is not a uniform list — it starts with the current-workspace badge — and drag
/// targeting, hover hit-testing, the popup anchor and the panel's own height all need the same
/// answers about that geometry. They are worked out once here instead of being re-derived —
/// differently — in each of those places.
struct StripLayout {
    enum Element: Identifiable {
        /// The accent badge showing the workspace currently in view.
        case badge
        case window(ManagedWindow)

        var id: String {
            switch self {
            case .badge: return "badge"
            case .window(let window): return "window-\(window.id)"
            }
        }

        var window: ManagedWindow? {
            if case .window(let window) = self { return window }
            return nil
        }
    }

    let elements: [Element]
    private let heights: [CGFloat]
    /// Offset from the top of the strip to the top edge of each element.
    private let tops: [CGFloat]
    /// Index into `elements` for each window, in queue order.
    private let windowElements: [Int]

    let totalHeight: CGFloat

    init(windows: [ManagedWindow], prefs: Preferences) {
        var elements: [Element] = []
        if prefs.showSpaceBadge { elements.append(.badge) }
        elements.append(contentsOf: windows.map { .window($0) })

        let heights = elements.map { element -> CGFloat in
            switch element {
            case .badge: return prefs.iconSize
            case .window: return StripMetrics.rowHeight(prefs: prefs)
            }
        }

        var tops: [CGFloat] = []
        var cursor = StripMetrics.padding
        for height in heights {
            tops.append(cursor)
            cursor += height + StripMetrics.spacing
        }

        self.elements = elements
        self.heights = heights
        self.tops = tops
        self.windowElements = elements.indices.filter { elements[$0].window != nil }
        // The trailing spacing of the last element is not part of the content.
        totalHeight = elements.isEmpty
            ? StripMetrics.padding * 2
            : cursor - StripMetrics.spacing + StripMetrics.padding
    }

    var windowCount: Int { windowElements.count }

    func topOffset(ofWindowAt index: Int) -> CGFloat {
        guard windowElements.indices.contains(index) else { return StripMetrics.padding }
        return tops[windowElements[index]]
    }

    func centreOffset(ofWindowAt index: Int) -> CGFloat {
        guard windowElements.indices.contains(index) else { return StripMetrics.padding }
        let element = windowElements[index]
        return tops[element] + heights[element] / 2
    }

    /// The window whose band contains `offset`, measured from the top of the strip content.
    func windowIndex(atOffsetFromTop offset: CGFloat) -> Int? {
        for (position, element) in windowElements.enumerated() {
            // The band includes the spacing below the row, so the gaps between icons stay live.
            let top = tops[element]
            let bottom = top + heights[element] + StripMetrics.spacing
            if offset >= top, offset < bottom { return position }
        }
        return nil
    }

    /// Like `windowIndex(atOffsetFromTop:)`, but never misses: a point above or below every icon
    /// resolves to the first or last one. Dragging needs an answer for any position the cursor can
    /// reach, including well outside the strip.
    func nearestWindowIndex(toOffsetFromTop offset: CGFloat) -> Int? {
        guard !windowElements.isEmpty else { return nil }
        if let hit = windowIndex(atOffsetFromTop: offset) { return hit }

        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for position in windowElements.indices {
            let distance = abs(centreOffset(ofWindowAt: position) - offset)
            if distance < bestDistance {
                bestDistance = distance
                best = position
            }
        }
        return best
    }
}
