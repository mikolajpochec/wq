import AppKit
import ApplicationServices

/// Pushes windows out from under the strip after the system lays them against the screen edge.
///
/// Only the Dock and menu bar can shrink `NSScreen.visibleFrame`, which is what zoom (double-clicking
/// a title bar), Fill and the built-in tiling all size windows to. There is no way to take part in
/// that calculation, so instead this watches for a window that has just been resized flush against
/// the strip's edge and trims it to start beside the strip — the same result, one frame later.
///
/// Only resizes are corrected, never plain moves, and never while a mouse button is down, so a window
/// the user is dragging around is left alone.
final class ScreenEdgeGuard {
    private let store: PreferencesStore
    private var pending: [CGWindowID: DispatchWorkItem] = [:]

    /// How close to the screen edge counts as laid against it.
    private static let tolerance: CGFloat = 2
    /// Waits for a resize to settle, since zoom animations report several sizes on the way.
    private static let settleDelay: TimeInterval = 0.2

    init(store: PreferencesStore) {
        self.store = store
    }

    func windowResized(_ element: AXUIElement) {
        guard isEnabled, let id = AXPrivate.windowID(of: element) else { return }
        pending[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.correct(element, id: id) }
        pending[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
    }

    private var isEnabled: Bool {
        store.prefs.reserveScreenSpace && store.prefs.trimWindowsAfterZoom
            && store.prefs.stripDisplay != .hidden
    }

    private func correct(_ element: AXUIElement, id: CGWindowID) {
        pending[id] = nil
        guard isEnabled else { return }

        // The user is still dragging an edge; look again once they let go.
        if NSEvent.pressedMouseButtons != 0 {
            windowResized(element)
            return
        }

        guard element.attribute(kAXSubroleAttribute, as: String.self) == kAXStandardWindowSubrole,
              element.boolAttribute("AXFullScreen") != true,
              let frame = Self.frame(of: element),
              let screen = Self.screen(containing: frame)
        else { return }

        let visible = Self.axRect(fromCocoa: screen.visibleFrame)
        let gap = CGFloat(RectangleIntegration.reservedWidth(for: store.prefs))
        var target = frame

        switch store.prefs.stripSide {
        case .left:
            let edge = visible.minX + gap
            guard abs(frame.minX - visible.minX) <= Self.tolerance, frame.maxX > edge + gap else { return }
            target.origin.x = edge
            target.size.width = frame.maxX - edge
        case .right:
            let edge = visible.maxX - gap
            guard abs(frame.maxX - visible.maxX) <= Self.tolerance, frame.minX < edge - gap else { return }
            target.size.width = edge - frame.minX
        }

        Diagnostics.note("edge guard: \(id) \(frame) -> \(target)")
        apply(target, to: element, id: id, attemptsLeft: Self.maxAttempts)
    }

    private static let maxAttempts = 4

    /// Sets size, then position, then size again — the order Rectangle uses. Many apps clamp a
    /// resize against their current position, so shrinking first and moving second leaves a window
    /// the right size in the wrong place, or moved but still full width and hanging off the screen.
    /// Zoom also animates, and an app can overwrite the result as its animation lands, so the frame
    /// is checked again shortly after and re-applied if it did not stick.
    private func apply(_ target: CGRect, to element: AXUIElement, id: CGWindowID, attemptsLeft: Int) {
        var size = target.size
        var origin = target.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return }
        _ = element.setAttribute(kAXSizeAttribute, value: sizeValue)
        _ = element.setAttribute(kAXPositionAttribute, value: originValue)
        _ = element.setAttribute(kAXSizeAttribute, value: sizeValue)

        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            // The user has taken hold of the window; it is theirs now.
            guard let self, NSEvent.pressedMouseButtons == 0, let frame = Self.frame(of: element) else { return }
            let settled = abs(frame.minX - target.minX) <= Self.tolerance
                && abs(frame.maxX - target.maxX) <= Self.tolerance
            guard !settled else { return }
            Diagnostics.note("edge guard: \(id) did not stick (\(frame)), retrying")
            self.apply(target, to: element, id: id, attemptsLeft: attemptsLeft - 1)
        }
    }

    // MARK: - Geometry

    /// Window frame in accessibility coordinates: origin at the top left of the primary screen,
    /// y growing downwards.
    private static func frame(of element: AXUIElement) -> CGRect? {
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

    private static func axRect(fromCocoa rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { axRect(fromCocoa: $0.frame).contains(centre) }
            ?? NSScreen.screens.max { a, b in
                area(axRect(fromCocoa: a.frame).intersection(frame)) < area(axRect(fromCocoa: b.frame).intersection(frame))
            }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
