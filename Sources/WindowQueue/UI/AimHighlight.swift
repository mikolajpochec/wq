import AppKit

/// Outlines the aimed windows on screen while aiming mode is open.
///
/// The strip says which window is aimed at by name and icon; several windows of one application
/// look alike there, and a run of them says nothing about where they are. An outline drawn around
/// the windows themselves answers both at a glance. Only windows on the workspace in view can be
/// outlined — a window on another one is not on screen to draw around.
final class AimHighlightOverlay {
    private var panels: [CGWindowID: NSPanel] = [:]
    /// The one panel used for the flash after a focus change, which is never more than one window.
    private var flashPanel: NSPanel?
    private var flashWork: DispatchWorkItem?

    /// Outlines one window for a moment, in the selection's own colour, to say where focus landed.
    func flash(_ window: ManagedWindow, for duration: TimeInterval) {
        guard let frame = WindowTiler.frame(of: window), frame.width > 20, frame.height > 20 else { return }
        let panel = flashPanel ?? make()
        flashPanel = panel
        (panel.contentView as? HighlightView)?.style = .focus
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        OverlaySpace.shared.adopt(panel)
        panel.contentView?.needsDisplay = true

        flashWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            } completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Draws around exactly these windows, taking away whatever was drawn before.
    func show(_ windows: [ManagedWindow], cursor: CGWindowID?) {
        var live: Set<CGWindowID> = []
        for window in windows {
            guard let frame = WindowTiler.frame(of: window), frame.width > 20, frame.height > 20 else { continue }
            live.insert(window.id)
            let panel = panels[window.id] ?? make()
            panels[window.id] = panel
            (panel.contentView as? HighlightView)?.style = window.id == cursor ? .aimCursor : .aimed
            // Exactly the window's own frame: the outline is drawn inside it, so a window against
            // the edge of the screen keeps its outline on screen with it.
            panel.setFrame(frame, display: true)
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
        enum Style {
            /// The window the aim is on, the rest of an aimed run, and the window focus just landed on.
            case aimCursor, aimed, focus

            var colour: NSColor {
                switch self {
                case .aimCursor, .aimed: return .systemOrange
                case .focus: return .controlAccentColor
                }
            }

            var opacity: CGFloat {
                switch self {
                case .aimCursor, .focus: return 1
                case .aimed: return 0.65
                }
            }
        }

        var style: Style = .aimCursor {
            didSet { if style != oldValue { needsDisplay = true } }
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
            // An outline only: a tint over the window would hide the very thing being pointed at.
            style.colour.withAlphaComponent(style.opacity).setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }

        private var lineWidth: CGFloat { AimHighlightOverlay.lineWidth }
    }
}
