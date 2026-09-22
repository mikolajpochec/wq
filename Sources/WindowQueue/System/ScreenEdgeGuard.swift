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
    /// The last settled frame of each window we have heard from, so a zoom can be undone.
    private var knownFrames: [CGWindowID: CGRect] = [:]
    /// Windows we trimmed after a zoom: the frame we gave them and the one they had before.
    private var trimmed: [CGWindowID: (applied: CGRect, previous: CGRect?)] = [:]
    private var settling: [CGWindowID: DispatchWorkItem] = [:]
    /// While our own frame changes land, the move notifications they cause are not the user's.
    private var applyingUntil: [CGWindowID: Date] = [:]

    /// How close to the screen edge counts as laid against it.
    private static let tolerance: CGFloat = 2
    /// Waits for a resize to settle, since zoom animations report several sizes on the way.
    private static let settleDelay: TimeInterval = 0.3

    init(store: PreferencesStore) {
        self.store = store
    }

    /// A window moved or took focus: remember where it is, so zooming it can be reversed later.
    ///
    /// Recorded only once the window has been still for a moment. A zoom animation moves the window
    /// before it reports a resize, and its halfway frames are not somewhere to go back to.
    func windowSettled(_ element: AXUIElement) {
        guard isEnabled, let id = AXPrivate.windowID(of: element),
              pending[id] == nil, !isApplying(id)
        else { return }
        settling[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pending[id] == nil, !self.isApplying(id),
                  let frame = Self.frame(of: element)
            else { return }
            self.settling[id] = nil
            self.settle(id, at: frame)
        }
        settling[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func isApplying(_ id: CGWindowID) -> Bool {
        (applyingUntil[id] ?? .distantPast) > Date()
    }

    func windowResized(_ element: AXUIElement) {
        // Our own frame changes, and an app pushing back against them, are handled by the checks
        // that follow each change; reading them as the user zooming would undo the correction.
        guard isEnabled, let id = AXPrivate.windowID(of: element), !isApplying(id) else { return }
        settling[id]?.cancel()
        settling[id] = nil
        pending[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.correct(element, id: id) }
        pending[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
    }

    private var isEnabled: Bool {
        store.prefs.reserveScreenSpace && store.prefs.trimWindowsOutsideReservation
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

        // `AXFullScreen` cannot tell the two apart: a zoomed window reports it too. A window in real
        // fullscreen covers the whole screen, menu bar included; a zoomed one stops below it.
        guard element.attribute(kAXSubroleAttribute, as: String.self) == kAXStandardWindowSubrole,
              let frame = Self.frame(of: element),
              let screen = Self.screen(containing: frame),
              !Self.approximatelyEqual(frame, Self.axRect(fromCocoa: screen.frame))
        else { return }

        let visible = Self.axRect(fromCocoa: screen.visibleFrame)
        let gap = CGFloat(RectangleIntegration.reservedWidth(for: store.prefs))
        var target = frame

        // Accessibility coordinates grow downwards, so "top" is the smaller y.
        switch store.prefs.stripSide {
        case .left:
            let edge = visible.minX + gap
            guard abs(frame.minX - visible.minX) <= Self.tolerance, frame.maxX > edge + gap else {
                return settle(id, at: frame)
            }
            target.origin.x = edge
            target.size.width = frame.maxX - edge
        case .right:
            let edge = visible.maxX - gap
            guard abs(frame.maxX - visible.maxX) <= Self.tolerance, frame.minX < edge - gap else {
                return settle(id, at: frame)
            }
            target.size.width = edge - frame.minX
        case .top:
            let edge = visible.minY + gap
            guard abs(frame.minY - visible.minY) <= Self.tolerance, frame.maxY > edge + gap else {
                return settle(id, at: frame)
            }
            target.origin.y = edge
            target.size.height = frame.maxY - edge
        case .bottom:
            let edge = visible.maxY - gap
            guard abs(frame.maxY - visible.maxY) <= Self.tolerance, frame.minY < edge - gap else {
                return settle(id, at: frame)
            }
            target.size.height = edge - frame.minY
        }

        // The app does not know its zoomed frame was trimmed, so zooming again — to get back out —
        // makes it zoom in once more. A zoom straight from the frame we trimmed it to is that
        // second zoom: put back the frame it had before the first one.
        if let record = trimmed[id], let previous = record.previous,
           let known = knownFrames[id], Self.approximatelyEqual(known, record.applied) {
            Diagnostics.note("edge guard: \(id) zoomed back out to \(previous)")
            trimmed[id] = nil
            knownFrames[id] = previous
            apply(previous, to: element, id: id)
            return
        }

        Diagnostics.note("edge guard: \(id) \(frame) -> \(target)")
        trimmed[id] = (applied: target, previous: knownFrames[id])
        knownFrames[id] = target
        apply(target, to: element, id: id)
    }

    private func settle(_ id: CGWindowID, at frame: CGRect) {
        knownFrames[id] = frame
        if let record = trimmed[id], !Self.approximatelyEqual(record.applied, frame) {
            trimmed[id] = nil
        }
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// When to look again after setting a frame, counted from the first attempt. Apps that animate
    /// their own zoom, or snap to a character grid like terminals do, can overwrite the frame a
    /// while after accepting it.
    private static let checkDelays: [TimeInterval] = [0.15, 0.35, 0.7, 1.2]

    /// Sets size, then position, then size again — the order Rectangle uses. Many apps clamp a
    /// resize against their current position, so shrinking first and moving second leaves a window
    /// the right size in the wrong place, or moved but still full width and hanging off the screen.
    /// The whole frame is then checked a few times and re-applied whenever it has drifted.
    private func apply(_ target: CGRect, to element: AXUIElement, id: CGWindowID, check: Int = 0) {
        var size = target.size
        var origin = target.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return }
        let lastCheck = Self.checkDelays.last ?? 0
        applyingUntil[id] = Date().addingTimeInterval(lastCheck + 0.5)
        // Setting a frame while the app is in enhanced accessibility mode makes AppKit animate it,
        // so the trim would crawl into place; see `WindowTiler.withoutAnimation`.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = AXPrivate.application(pid)
        let wasEnhanced = app.boolAttribute("AXEnhancedUserInterface") ?? false
        if wasEnhanced { app.setAttribute("AXEnhancedUserInterface", value: kCFBooleanFalse) }
        // Move, then resize: a window drawn at the new size in the old place reads as a flicker.
        // Only an app that clamps the resize against its old position needs the other order.
        _ = element.setAttribute(kAXPositionAttribute, value: originValue)
        _ = element.setAttribute(kAXSizeAttribute, value: sizeValue)
        if let landed = Self.frame(of: element), !Self.approximatelyEqual(landed, target) {
            _ = element.setAttribute(kAXSizeAttribute, value: sizeValue)
            _ = element.setAttribute(kAXPositionAttribute, value: originValue)
            _ = element.setAttribute(kAXSizeAttribute, value: sizeValue)
        }
        if wasEnhanced { app.setAttribute("AXEnhancedUserInterface", value: kCFBooleanTrue) }
        scheduleCheck(target, element: element, id: id, check: check)
    }

    private func scheduleCheck(_ target: CGRect, element: AXUIElement, id: CGWindowID, check: Int) {
        guard Self.checkDelays.indices.contains(check) else { return }
        let previousDelay = check == 0 ? 0 : Self.checkDelays[check - 1]
        let wait = Self.checkDelays[check] - previousDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            // The user has taken hold of the window; it is theirs now.
            guard let self, NSEvent.pressedMouseButtons == 0, let frame = Self.frame(of: element) else { return }
            if Self.approximatelyEqual(frame, target) {
                self.scheduleCheck(target, element: element, id: id, check: check + 1)
            } else {
                Diagnostics.note("edge guard: \(id) drifted to \(frame), re-applying \(target)")
                self.apply(target, to: element, id: id, check: check + 1)
            }
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
