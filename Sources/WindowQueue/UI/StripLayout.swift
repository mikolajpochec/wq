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
        /// Where the windows of an empty workspace the user is on would go.
        case emptySlot
        /// The windows a maximized window covers, collapsed into one tile.
        case hiddenStack(windows: [ManagedWindow])
        /// A group of windows, which the strip shows as a single entry.
        case group(id: Int, windows: [ManagedWindow])

        var id: String {
            switch self {
            case .badge: return "badge"
            case .emptySlot: return "empty-slot"
            case .hiddenStack: return "hidden-stack"
            case .group(let id, _): return "group-\(id)"
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
    /// Index into `elements` for each window, in queue order. Windows collapsed into the hidden
    /// stack all point at that one element.
    private let windowElements: [Int]

    let totalHeight: CGFloat

    /// Where the empty-workspace marker goes among the windows.
    enum SlotPlacement: Equatable {
        case before(CGWindowID)
        case end
    }

    /// - Parameters:
    ///   - collapsed: windows drawn as one stacked tile instead of a row each.
    ///   - groups: windows that belong to a group, by group number, drawn as one entry each.
    init(windows: [ManagedWindow], prefs: Preferences, slot: SlotPlacement? = nil,
         collapsed: Set<CGWindowID> = [], groups: [CGWindowID: Int] = [:]) {
        var elements: [Element] = []
        if prefs.showSpaceBadge { elements.append(.badge) }
        var windowElements: [Int] = []
        var stackElement: Int?
        let hidden = windows.filter { collapsed.contains($0.id) }
        var groupElements: [Int: Int] = [:]
        for window in windows {
            // A window in a group is shown in that group, cascade or no cascade: the fullscreen
            // cascade for its windows belongs in the group's own strip.
            if let number = groups[window.id] {
                if let existing = groupElements[number] {
                    windowElements.append(existing)
                } else {
                    let members = windows.filter { groups[$0.id] == number }
                    groupElements[number] = elements.count
                    windowElements.append(elements.count)
                    elements.append(.group(id: number, windows: members))
                }
                continue
            }
            if collapsed.contains(window.id) {
                if stackElement == nil {
                    stackElement = elements.count
                    elements.append(.hiddenStack(windows: hidden))
                }
                windowElements.append(stackElement!)
            } else {
                windowElements.append(elements.count)
                elements.append(.window(window))
            }
        }
        switch slot {
        case .before(let id):
            let index = elements.firstIndex { $0.window?.id == id } ?? elements.count
            elements.insert(.emptySlot, at: index)
        case .end:
            elements.append(.emptySlot)
        case nil:
            break
        }

        let heights = elements.map { element -> CGFloat in
            switch element {
            // The badge is inset like a row, so the gap above it matches the gap beside it.
            case .badge: return StripMetrics.rowHeight(prefs: prefs)
            case .window: return StripMetrics.rowHeight(prefs: prefs)
            case .emptySlot: return StripMetrics.slotLength(prefs: prefs)
            case .hiddenStack, .group: return StripMetrics.stackLength(prefs: prefs)
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
        // The empty slot shifts the elements after it, so the map is built against the final list.
        let slotIndex = elements.firstIndex { if case .emptySlot = $0 { return true } else { return false } }
        self.windowElements = windowElements.map { index in
            guard let slotIndex, index >= slotIndex else { return index }
            return index + 1
        }
        // The trailing spacing of the last element is not part of the content.
        totalHeight = elements.isEmpty
            ? StripMetrics.padding * 2
            : cursor - StripMetrics.spacing + StripMetrics.padding
    }

    var windowCount: Int { windowElements.count }

    /// Windows drawn inside the hidden stack, in queue order.
    var hiddenWindows: [ManagedWindow] {
        for element in elements {
            if case .hiddenStack(let windows) = element { return windows }
        }
        return []
    }

    func topOffset(ofWindowAt index: Int) -> CGFloat {
        guard windowElements.indices.contains(index) else { return StripMetrics.padding }
        return tops[windowElements[index]]
    }

    func centreOffset(ofWindowAt index: Int) -> CGFloat {
        guard windowElements.indices.contains(index) else { return StripMetrics.padding }
        let element = windowElements[index]
        return tops[element] + heights[element] / 2
    }

    /// The window whose band contains `offset`, measured from the top of the strip content. A point
    /// on the hidden stack answers with the first window inside it.
    func windowIndex(atOffsetFromTop offset: CGFloat) -> Int? {
        for (position, element) in windowElements.enumerated() {
            // The band includes the spacing below the row, so the gaps between icons stay live.
            let top = tops[element]
            let bottom = top + heights[element] + StripMetrics.spacing
            if offset >= top, offset < bottom { return position }
        }
        return nil
    }

    /// Whether the point falls on the current-workspace badge at the head of the strip.
    func isBadge(atOffsetFromTop offset: CGFloat) -> Bool {
        for (index, element) in elements.enumerated() {
            guard case .badge = element else { continue }
            return offset >= tops[index] && offset < tops[index] + heights[index] + StripMetrics.spacing
        }
        return false
    }

    /// Whether the point falls on the tile the covered windows are collapsed into.
    func isHiddenStack(atOffsetFromTop offset: CGFloat) -> Bool {
        for (index, element) in elements.enumerated() {
            guard case .hiddenStack = element else { continue }
            return offset >= tops[index] && offset < tops[index] + heights[index] + StripMetrics.spacing
        }
        return false
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
