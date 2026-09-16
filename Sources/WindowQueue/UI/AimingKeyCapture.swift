import AppKit
import CoreGraphics

/// Keyboard handling for aiming mode: move the aim, confirm it, or back out.
///
/// Focus must not move until the user confirms, so the keys are taken with a `KeyboardGrabber`
/// rather than by giving a panel key focus.
final class AimingKeyCapture {
    enum Key {
        case up, down, left, right
        /// `[` and `]`.
        case back, forward
        /// Return or keypad Enter.
        case enter
        case space
        case cancel
    }

    struct Press {
        let key: Key
        /// Shift was held: grow the aimed run instead of moving the aim.
        let extends: Bool
        /// Option, Command or Control was held: move the aimed windows along the queue.
        let moves: Bool
    }

    var onKey: ((Press) -> Void)?
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
        case 36, 76: key = .enter
        case 49: key = .space
        case 53: key = .cancel
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 33: key = .back
        case 30: key = .forward
        default: key = nil
        }

        if Diagnostics.isEnabled {
            Diagnostics.note("aiming key code=\(event.keyCode) mapped=\(key.map(String.init(describing:)) ?? "none")")
        }

        // Acting inside the callback would hold up event delivery, and a slow tap gets disabled.
        if let key {
            let flags = event.flags
            let press = Press(key: key,
                              extends: flags.contains(.maskShift),
                              moves: !flags.intersection([.maskAlternate, .maskCommand, .maskControl]).isEmpty)
            DispatchQueue.main.async { [weak self] in self?.onKey?(press) }
        }

        // Every key press is swallowed: while aiming, none of them belong to the app in front.
        return true
    }
}
