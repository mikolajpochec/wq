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
    private var hideWorkItem: DispatchWorkItem?

    /// Supplies the on-screen rect of a window's row in the strip, so the toast appears right
    /// beside the icon it describes rather than in the middle of the strip.
    var anchorProvider: ((CGWindowID) -> (frame: NSRect, side: StripSide)?)?

    init(store: PreferencesStore) {
        self.store = store
    }

    func show(_ window: ManagedWindow) {
        guard store.prefs.toastEnabled else { return }

        let view = ToastView(title: window.displayTitle, subtitle: window.appName)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let clamped = NSSize(width: min(max(size.width, 140), 420), height: size.height)

        let panel = self.panel ?? OverlayPanel(contentRect: NSRect(origin: .zero, size: clamped))
        panel.contentView = hosting
        self.panel = panel

        panel.setFrame(NSRect(origin: position(for: clamped, windowID: window.id), size: clamped),
                       display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + store.prefs.toastDuration, execute: item)
    }

    private func position(for size: NSSize, windowID: CGWindowID) -> NSPoint {
        let margin: CGFloat = 8
        let visible = NSScreen.main?.visibleFrame ?? .zero

        guard let anchor = anchorProvider?(windowID) else {
            return NSPoint(x: visible.minX + margin, y: visible.midY - size.height / 2)
        }

        let x = anchor.side == .left
            ? anchor.frame.maxX + margin
            : anchor.frame.minX - size.width - margin
        // Keep the toast on screen when the row is near the top or bottom edge.
        let y = min(max(anchor.frame.midY - size.height / 2, visible.minY + margin),
                    visible.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
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
