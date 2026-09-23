import AppKit

/// Outlines the aimed windows on screen while aiming mode is open.
///
/// The strip says which window is aimed at by name and icon; several windows of one application
/// look alike there, and a run of them says nothing about where they are. An outline drawn around
/// the windows themselves answers both at a glance. Only windows on the workspace in view can be
/// outlined — a window on another one is not on screen to draw around.
final class AimHighlightOverlay {
    private var panels: [CGWindowID: NSPanel] = [:]

    /// Draws around exactly these windows, taking away whatever was drawn before.
    func show(_ windows: [ManagedWindow], cursor: CGWindowID?) {
        var live: Set<CGWindowID> = []
        for window in windows {
            guard let frame = WindowTiler.frame(of: window), frame.width > 20, frame.height > 20 else { continue }
            live.insert(window.id)
            let panel = panels[window.id] ?? make()
            panels[window.id] = panel
            (panel.contentView as? HighlightView)?.isCursor = window.id == cursor
            // The outline is drawn inside its own panel, which is a little larger than the window so
            // the line is not hidden under the window's own edge.
            panel.setFrame(frame.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth), display: true)
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                OverlaySpace.shared.adopt(panel)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
            panel.contentView?.needsDisplay = true
        }

        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }
    }

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
    }

    private static let lineWidth: CGFloat = 3

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above the dimming, which sits one level below the strip, so the outlined windows read as
        // lifted out of the dimmed screen.
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = HighlightView()
        return panel
    }

    /// The outline itself: orange, like the aim on the strip, and brighter for the window the aim
    /// is actually on when several are aimed at. Nothing is drawn inside it.
    private final class HighlightView: NSView {
        var isCursor = false {
            didSet { if isCursor != oldValue { needsDisplay = true } }
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
            // An outline only: a tint over the window would hide the very thing being pointed at.
            NSColor.systemOrange.withAlphaComponent(isCursor ? 1 : 0.65).setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }

        private var lineWidth: CGFloat { AimHighlightOverlay.lineWidth }
    }
}
