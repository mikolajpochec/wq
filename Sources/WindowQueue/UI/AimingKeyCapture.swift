import AppKit

/// Takes keyboard focus while aiming mode is on.
///
/// Aiming has to swallow Return, Space and the arrows, and a global event monitor cannot do that —
/// monitors observe, they do not consume, so Return would still reach whatever app is in front. So a
/// tiny transparent panel becomes key for the duration. It is `.nonactivatingPanel`, so it takes key
/// focus without activating WindowQueue or putting a Dock icon on screen.
final class AimingKeyCapture {
    enum Key {
        case previous, next, commit, cancel
    }

    var onKey: ((Key) -> Void)?
    /// Fires when the panel loses key focus, which ends the mode.
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?

    var isActive: Bool { panel != nil }

    func begin(near frame: NSRect?) {
        guard panel == nil else { return }

        let origin = frame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? .zero
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let view = CaptureView()
        view.onKey = { [weak self] key in self?.onKey?(key) }
        view.onResign = { [weak self] in self?.onDismiss?() }
        panel.contentView = view

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    func end() {
        panel?.orderOut(nil)
        panel = nil
    }

    private final class CaptureView: NSView {
        var onKey: ((Key) -> Void)?
        var onResign: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch Int(event.keyCode) {
            case 36, 76, 49:                 // Return, keypad Enter, Space
                onKey?(.commit)
            case 53:                         // Escape
                onKey?(.cancel)
            case 126, 33:                    // Up, [
                onKey?(.previous)
            case 125, 30:                    // Down, ]
                onKey?(.next)
            default:
                // Swallowed rather than passed on: while aiming, stray keys must not reach the app
                // underneath, which is not the one the user is looking at.
                NSSound.beep()
            }
        }

        override func resignFirstResponder() -> Bool {
            onResign?()
            return true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: window
            )
        }

        @objc private func windowResignedKey() {
            onResign?()
        }
    }
}
