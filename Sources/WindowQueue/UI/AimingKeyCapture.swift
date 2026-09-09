import AppKit
import CoreGraphics

/// Keyboard handling for aiming mode: move the aim, confirm it, or back out.
///
/// Focus must not move until the user confirms, so the keys are taken with a `KeyboardGrabber`
/// rather than by giving a panel key focus.
final class AimingKeyCapture {
    enum Key {
        case previous, next, commit, cancel
    }

    var onKey: ((Key) -> Void)?
    /// Fires when the mode should end without the user having confirmed anything.
    var onDismiss: (() -> Void)? {
        didSet { grabber.onDismiss = onDismiss }
    }

    private let grabber = KeyboardGrabber()

    init() {
        grabber.onKeyDown = { [weak self] event in
            self?.handle(event) ?? false
        }
    }

    var isActive: Bool { grabber.isActive }

    func begin() {
        grabber.begin()
    }

    func end() {
        grabber.end()
    }

    private func handle(_ event: CGEvent) -> Bool {
        let key: Key?
        switch event.keyCode {
        case 36, 76, 49:            // Return, keypad Enter, Space
            key = .commit
        case 53:                    // Escape
            key = .cancel
        case 126, 123, 33:          // Up, Left, [
            key = .previous
        case 125, 124, 30:          // Down, Right, ]
            key = .next
        default:
            key = nil
        }

        if Diagnostics.isEnabled {
            Diagnostics.note("aiming key code=\(event.keyCode) mapped=\(key.map(String.init(describing:)) ?? "none")")
        }

        // Acting inside the callback would hold up event delivery, and a slow tap gets disabled.
        if let key {
            DispatchQueue.main.async { [weak self] in self?.onKey?(key) }
        }

        // Every key press is swallowed: while aiming, none of them belong to the app in front.
        return true
    }
}
