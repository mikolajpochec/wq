import AppKit

/// Shows where a window will land while its icon is dragged along the strip.
///
/// Only meaningful for a window held in a layout: dropping it somewhere else in the queue lays the
/// group out again, and this is the cell it will get.
final class TilePreviewOverlay {
    private var panel: NSPanel?

    /// - Parameter frame: the cell, in Cocoa screen coordinates, or nil to take the preview away.
    func show(_ frame: NSRect?) {
        guard let frame else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? make()
        self.panel = panel
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            OverlaySpace.shared.adopt(panel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = PreviewView()
        return panel
    }

    /// A filled outline in the accent colour, drawn straight rather than through SwiftUI: it is one
    /// rectangle that moves with the drag, and a hosting view would be rebuilt on every step.
    private final class PreviewView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let inset = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }
}
