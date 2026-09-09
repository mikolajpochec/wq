import AppKit
import CoreGraphics

/// Takes the keyboard for a modal moment, without taking focus.
///
/// The obvious alternatives both fail here. An `NSEvent` monitor observes but cannot consume, so
/// Return and the arrows would still reach whatever app is in front; and an accessory application
/// that is not active cannot make even a `.nonactivatingPanel` key, so a panel receives nothing —
/// and activating the app to fix that would move focus, which these modes exist to avoid.
///
/// A session-level event tap can return nil to swallow an event, needs no focus, and lives only as
/// long as the mode does.
final class KeyboardGrabber {
    /// Return true to swallow the key press, false to let it through.
    var onKeyDown: ((CGEvent) -> Bool)?
    /// The tap could not be created, or nothing happened for a long time.
    var onDismiss: (() -> Void)?

    /// The tap swallows key presses, so a mode left open by mistake would lock the keyboard out of
    /// every other application. It closes itself if nothing happens.
    var idleTimeout: TimeInterval = 15

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var idleTimer: Timer?

    var isActive: Bool { tap != nil }

    func begin() {
        guard tap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let grabber = Unmanaged<KeyboardGrabber>.fromOpaque(refcon).takeUnretainedValue()
            return grabber.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
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
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) {
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

        restartIdleTimer()
        let swallow = onKeyDown?(event) ?? false
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}

extension CGEvent {
    var keyCode: Int {
        Int(getIntegerValueField(.keyboardEventKeycode))
    }

    /// The characters this key press would type, ignoring modifiers we do not care about.
    var typedCharacters: String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: buffer.count,
                                 actualStringLength: &length,
                                 unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
