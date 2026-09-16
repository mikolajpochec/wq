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
final class ToastController {
    private let store: PreferencesStore
    private var panel: OverlayPanel?
    /// Built once and updated in place: while an icon is dragged this is refreshed on every slot
    /// change, and rebuilding the hosting view each time is what makes a press feel sluggish.
    private var hosting: NSHostingView<ToastView>?
    private var hideWorkItem: DispatchWorkItem?

    /// Supplies the on-screen rect of a window's row in the strip, so the toast appears right
    /// beside the icon it describes rather than in the middle of the strip.
    var anchorProvider: ((CGWindowID) -> (frame: NSRect, side: StripSide)?)?

    init(store: PreferencesStore) {
        self.store = store
    }

    /// - Parameter pinned: keep the popup up instead of hiding it after the configured delay, for
    ///   as long as the icon is held.
    func show(_ window: ManagedWindow, pinned: Bool = false) {
        guard store.prefs.toastEnabled else { return }

        let view = ToastView(title: window.displayTitle, subtitle: window.appName)
        let hosting: NSHostingView<ToastView>
        if let existing = self.hosting {
            hosting = existing
            hosting.rootView = view
        } else {
            hosting = NSHostingView(rootView: view)
            self.hosting = hosting
        }

        let size = hosting.fittingSize
        let clamped = NSSize(width: min(max(size.width, 140), 420), height: size.height)

        let panel: OverlayPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: clamped))
            panel.contentView = hosting
            self.panel = panel
        }

        // Already on screen — while an icon is being dragged this is called on every slot change,
        // so move it rather than fading it in again.
        let wasVisible = panel.isVisible && panel.alphaValue > 0
        panel.setFrame(NSRect(origin: position(for: clamped, windowID: window.id), size: clamped),
                       display: true)

        if wasVisible {
            panel.orderFrontRegardless()
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

        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !pinned else { return }
        scheduleHide(after: store.prefs.toastDuration)
    }

    /// Ends a pinned popup, leaving it up briefly so the final position is readable.
    func endHold() {
        guard panel != nil else { return }
        scheduleHide(after: min(store.prefs.toastDuration, 0.6))
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func position(for size: NSSize, windowID: CGWindowID) -> NSPoint {
        let margin: CGFloat = 8
        let anchor = anchorProvider?(windowID)
        // Clamp to the screen the icon is on, which with a strip on every monitor need not be the
        // main one.
        let screen = anchor.flatMap { anchor in
            NSScreen.screens.first { $0.frame.intersects(anchor.frame) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        guard let anchor else {
            return NSPoint(x: visible.minX + margin, y: visible.midY - size.height / 2)
        }

        // Beside the icon, on the screen side of the strip, and kept on screen near the ends.
        let clampedY = min(max(anchor.frame.midY - size.height / 2, visible.minY + margin),
                           visible.maxY - size.height - margin)
        let clampedX = min(max(anchor.frame.midX - size.width / 2, visible.minX + margin),
                           visible.maxX - size.width - margin)
        switch anchor.side {
        case .left: return NSPoint(x: anchor.frame.maxX + margin, y: clampedY)
        case .right: return NSPoint(x: anchor.frame.minX - size.width - margin, y: clampedY)
        case .top: return NSPoint(x: clampedX, y: anchor.frame.minY - size.height - margin)
        case .bottom: return NSPoint(x: clampedX, y: anchor.frame.maxY + margin)
        }
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
