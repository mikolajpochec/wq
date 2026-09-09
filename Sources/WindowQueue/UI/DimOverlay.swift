import AppKit

/// Dims every screen while aiming mode is on, so the strip is the only thing that reads clearly.
///
/// One panel per display, sitting above ordinary windows but below the strip and the name popup, so
/// the strip stands out without being covered. The panels ignore the mouse: this is a backdrop, not
/// a click target, and aiming is driven from the keyboard.
final class DimOverlay {
    private let store: PreferencesStore
    private var panels: [NSPanel] = []

    init(store: PreferencesStore) {
        self.store = store
    }

    var isVisible: Bool { !panels.isEmpty }

    func show() {
        guard store.prefs.aimingDimOpacity > 0 else { return }
        hide(animated: false)

        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            // One level below the strip and the popup, which both sit at `statusWindow + 1`.
            panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                        .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .black
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        let target = store.prefs.aimingDimOpacity
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panels.forEach { $0.animator().alphaValue = target }
        }
    }

    func hide(animated: Bool = true) {
        let closing = panels
        panels = []
        guard !closing.isEmpty else { return }

        guard animated else {
            closing.forEach { $0.orderOut(nil) }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
    }
}
