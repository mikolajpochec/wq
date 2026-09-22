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
    /// - Parameter area: the space to fill, in Cocoa screen coordinates.
    /// - Returns: the windows that were placed; a window with no accessibility element — one on a
    ///   workspace not visited yet — cannot be.
    @discardableResult
    static func tile(_ windows: [ManagedWindow], layout: TileLayout, in area: NSRect) -> [ManagedWindow] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Accessibility coordinates start at the top left of the menu bar screen, y downwards.
        let top = primaryHeight - area.maxY
        var placed: [ManagedWindow] = []

        for (window, unit) in zip(windows, layout.frames) {
            guard let element = window.element else { continue }
            let frame = CGRect(x: (area.minX + unit.minX * area.width).rounded(),
                               y: (top + unit.minY * area.height).rounded(),
                               width: (unit.width * area.width).rounded(),
                               height: (unit.height * area.height).rounded())
            if window.isMinimized {
                element.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
            }
            setFrame(frame, of: element, window: window)
            placed.append(window)
        }
        Diagnostics.note("tiled \(placed.count)/\(windows.count) windows as \(layout.name)")
        return placed
    }

    /// When to look at a tiled window again. A window that has just arrived from another
    /// workspace, or whose app animates or snaps its own frame, can accept a size and then lose the
    /// position, so the whole frame is checked a few times and set again whenever it slipped.
    private static let checkDelays: [TimeInterval] = [0.15, 0.4, 0.8, 1.5]

    private static func setFrame(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow, check: Int = 0) {
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return }
        // Size, position, size: an app may clamp a resize against where the window still is.
        element.setAttribute(kAXSizeAttribute, value: sizeValue)
        element.setAttribute(kAXPositionAttribute, value: originValue)
        element.setAttribute(kAXSizeAttribute, value: sizeValue)

        scheduleCheck(frame, of: element, window: window, check: check)
    }

    private static func scheduleCheck(_ frame: CGRect, of element: AXUIElement, window: ManagedWindow, check: Int) {
        guard checkDelays.indices.contains(check) else { return }
        let wait = checkDelays[check] - (check == 0 ? 0 : checkDelays[check - 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard let current = currentFrame(of: element) else { return }
            let slipped = abs(current.minX - frame.minX) > 2 || abs(current.minY - frame.minY) > 2
                || abs(current.width - frame.width) > 2 || abs(current.height - frame.height) > 2
            if slipped {
                Diagnostics.note("tiling: \(window.appName) id=\(window.id) at \(current), setting \(frame) again")
                setFrame(frame, of: element, window: window, check: check + 1)
            } else {
                scheduleCheck(frame, of: element, window: window, check: check + 1)
            }
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
    static func fill(_ window: ManagedWindow, in area: NSRect) -> Bool {
        let layout = TileLayout(name: "Maximize", frames: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        return !tile([window], layout: layout, in: area).isEmpty
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
