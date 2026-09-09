import AppKit
import CoreGraphics

/// Grabs the keyboard while aiming mode is on.
///
/// The obvious approach — a small panel that takes key focus — does not work here twice over. An
/// accessory application that is not active cannot make a `.nonactivatingPanel` key, so the panel
/// silently receives nothing; and activating the app to fix that would move focus, which is exactly
/// what aiming mode exists to avoid.
///
/// So the keys are taken with an event tap instead. A tap placed at the session level with
/// `.defaultTap` may return nil to swallow an event, which an `NSEvent` monitor cannot do — monitors
/// observe only, so Return and the brackets would still reach whatever app is in front. Nothing is
/// focused, nothing is activated, and the tap exists only for as long as the mode does.
final class AimingKeyCapture {
    enum Key {
        case previous, next, commit, cancel
    }

    var onKey: ((Key) -> Void)?
    /// Fires when the mode should end without the user having confirmed anything.
    var onDismiss: (() -> Void)?

    /// The tap swallows every key press, so a mode left open by mistake would lock the keyboard out
    /// of every other application. It closes itself if nothing happens.
    private static let idleTimeout: TimeInterval = 15

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var idleTimer: Timer?

    var isActive: Bool { tap != nil }

    func begin() {
        guard tap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<AimingKeyCapture>.fromOpaque(refcon).takeUnretainedValue()
            return capture.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
            // Without the tap there is no way to run the mode without disturbing focus.
            onDismiss?()
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        restartIdleTimer()
    }

    func end() {
        idleTimer?.invalidate()
        idleTimer = nil

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) {
            [weak self] _ in
            self?.onDismiss?()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or that the user interrupted; re-arming it
        // is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let key: Key?
        switch keyCode {
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

        restartIdleTimer()

        if Diagnostics.isEnabled {
            Diagnostics.note("aiming key code=\(keyCode) mapped=\(key.map(String.init(describing:)) ?? "none")")
        }

        // Acting inside the callback would hold up event delivery, and a slow tap gets disabled.
        if let key {
            DispatchQueue.main.async { [weak self] in self?.onKey?(key) }
        }

        // Every key press is swallowed: while aiming, none of them belong to the app in front.
        return nil
    }
}
