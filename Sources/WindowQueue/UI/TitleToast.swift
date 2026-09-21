import AppKit
import SwiftUI

private struct ToastView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Transient popup showing the name of the window that was just selected.
///
/// Usually one bubble beside the strip the user is looking at. While aiming, the aimed window's name
/// is shown beside every strip, since the aim is on all of them at once.
final class ToastController {
    /// One popup window. Built once and updated in place: while an icon is dragged this is
    /// refreshed on every slot change, and rebuilding the hosting view each time is what makes a
    /// press feel sluggish.
    private final class Bubble {
        let panel: OverlayPanel
        let hosting: NSHostingView<ToastView>

        init(view: ToastView) {
            hosting = NSHostingView(rootView: view)
            panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
            panel.contentView = hosting
        }
    }

    private let store: PreferencesStore
    private var bubbles: [Bubble] = []
    private var hideWorkItem: DispatchWorkItem?
    /// Bumped by every show, so a fade-out already under way does not take down a newer popup.
    private var generation = 0

    /// Supplies the on-screen rect of a window's row in the strip, so the toast appears right
    /// beside the icon it describes rather than in the middle of the strip.
    var anchorProvider: ((CGWindowID) -> (frame: NSRect, side: StripSide)?)?
    /// The window's row on every strip on screen, for a popup shown beside each of them.
    var everyAnchorProvider: ((CGWindowID) -> [NSRect])?

    init(store: PreferencesStore) {
        self.store = store
    }

    /// - Parameters:
    ///   - pinned: keep the popup up instead of hiding it after the configured delay, for as long
    ///     as the icon is held.
    ///   - everywhere: beside every strip on screen rather than only the one in use.
    func show(_ window: ManagedWindow, pinned: Bool = false, everywhere: Bool = false) {
        show(title: window.displayTitle, subtitle: window.appName, beside: window.id,
             pinned: pinned, everywhere: everywhere)
    }

    /// A popup with any text, placed beside a window's icon.
    func show(title: String, subtitle: String, beside windowID: CGWindowID,
              pinned: Bool = false, everywhere: Bool = false) {
        guard store.prefs.toastEnabled else { return }
        generation += 1

        let side = store.prefs.stripSide
        var anchors: [NSRect?] = [anchorProvider?(windowID)?.frame]
        if everywhere, let all = everyAnchorProvider?(windowID), !all.isEmpty { anchors = all }

        let view = ToastView(title: title, subtitle: subtitle)
        while bubbles.count < anchors.count { bubbles.append(Bubble(view: view)) }

        for (bubble, anchor) in zip(bubbles, anchors) {
            bubble.hosting.rootView = view
            let size = bubble.hosting.fittingSize
            let clamped = NSSize(width: min(max(size.width, 140), 420), height: size.height)
            present(bubble, at: NSRect(origin: position(for: clamped, anchor: anchor, side: side), size: clamped))
        }
        // Bubbles for strips this popup does not point from.
        for bubble in bubbles.dropFirst(anchors.count) { bubble.panel.orderOut(nil) }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !pinned else { return }
        scheduleHide(after: store.prefs.toastDuration)
    }

    private func present(_ bubble: Bubble, at frame: NSRect) {
        let panel = bubble.panel
        // Already on screen — while an icon is being dragged this is called on every slot change,
        // so move it rather than fading it in again.
        let wasVisible = panel.isVisible && panel.alphaValue > 0
        panel.setFrame(frame, display: true)

        if wasVisible {
            panel.orderFrontRegardless()
            // It may be halfway through fading out; bring it back rather than let it finish.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // The strip lives in the overlay space above the desktops; the popup has to join it or
            // it would be drawn underneath the strip it points from.
            OverlaySpace.shared.adopt(panel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Ends a pinned popup, leaving it up briefly so the final position is readable.
    func endHold() {
        guard !bubbles.isEmpty else { return }
        scheduleHide(after: min(store.prefs.toastDuration, 0.6))
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func position(for size: NSSize, anchor: NSRect?, side: StripSide) -> NSPoint {
        let margin: CGFloat = 8
        // Clamp to the screen the icon is on, which with a strip on every monitor need not be the
        // main one.
        let screen = anchor.flatMap { anchor in
            NSScreen.screens.first { $0.frame.intersects(anchor) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        guard let anchor else {
            return NSPoint(x: visible.minX + margin, y: visible.midY - size.height / 2)
        }

        // Beside the icon, on the screen side of the strip, and kept on screen near the ends.
        let clampedY = min(max(anchor.midY - size.height / 2, visible.minY + margin),
                           visible.maxY - size.height - margin)
        let clampedX = min(max(anchor.midX - size.width / 2, visible.minX + margin),
                           visible.maxX - size.width - margin)
        switch side {
        case .left: return NSPoint(x: anchor.maxX + margin, y: clampedY)
        case .right: return NSPoint(x: anchor.minX - size.width - margin, y: clampedY)
        case .top: return NSPoint(x: clampedX, y: anchor.minY - size.height - margin)
        case .bottom: return NSPoint(x: clampedX, y: anchor.maxY + margin)
        }
    }

    /// Takes the popup down straight away, for when something else is about to take its place.
    func hideNow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        bubbles.forEach { $0.panel.orderOut(nil) }
    }

    private func hide() {
        let fading = generation
        let panels = bubbles.map(\.panel).filter(\.isVisible)
        guard !panels.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panels.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            // Shown again while fading: that popup is the one on screen now.
            guard self?.generation == fading else { return }
            panels.forEach { $0.orderOut(nil) }
        })
    }
}
