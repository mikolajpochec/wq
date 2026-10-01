import AppKit

/// Frames a whole monitor for a moment when work moves over to it.
///
/// With several monitors, the strip badge says which one is worked on only to someone already
/// looking at it; a jump between monitors lands focus somewhere the eye has to find. A frame
/// around the edge of the screen just arrived at answers that from the corner of the eye.
final class MonitorFrameOverlay {
    private var panel: NSPanel?
    private var work: DispatchWorkItem?

    /// Draws the frame around `screen`, holds it for `duration`, then lets it go.
    /// - Parameter fading: whether it fades away rather than going at once.
    func flash(_ screen: NSScreen, for duration: TimeInterval, fading: Bool = true) {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        OverlaySpace.shared.adopt(panel)
        panel.contentView?.needsDisplay = true

        work?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fading ? 0.45 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        work?.cancel()
        work = nil
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Over everything, menu bar and strip included: it is the screen's edge being drawn.
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = FrameView()
        return panel
    }

    /// A band along the screen's edges in the selection colour, solid at the edge and fading
    /// inwards, so it reads as the screen lighting up rather than as one more window outline.
    final class FrameView: NSView {
        static let width: CGFloat = 10

        override func draw(_ dirtyRect: NSRect) {
            let colour = NSColor.controlAccentColor
            let steps = 5
            for step in 0..<steps {
                let inset = CGFloat(step) * Self.width / CGFloat(steps)
                let band = Self.width / CGFloat(steps)
                let rect = bounds.insetBy(dx: inset + band / 2, dy: inset + band / 2)
                let path = NSBezierPath(rect: rect)
                path.lineWidth = band
                colour.withAlphaComponent(0.95 * (1 - CGFloat(step) / CGFloat(steps))).setStroke()
                path.stroke()
            }
        }
    }
}
